//
//  OsaurusConfigDocument.swift
//  osaurus
//
//  The declarative YAML configuration document — the single schema behind
//  `osaurus_config` (export / plan / apply), the `/admin/config/*` HTTP
//  endpoints, and `osaurus config` in the CLI.
//
//  Semantics are merge-by-default: a key that is ABSENT from the document
//  is left untouched; an explicit `null` clears an optional override back
//  to its default. `ConfigField` carries that three-way distinction
//  (absent / null / value) through Codable, which cannot otherwise
//  distinguish a missing key from an explicit null.
//
//  Secrets NEVER appear in this document, in any direction. Export writes
//  no secret material (there are no secret-bearing fields in the schema),
//  and apply never accepts one — credentials flow through the native
//  Keychain sheets exactly as they do in Settings.
//

import Foundation

// MARK: - ConfigField

/// Three-way field state for keys whose "unset" value is meaningful:
/// `absent` = leave unchanged, `null` = clear the override, `value` = set.
public enum ConfigField<T: Equatable & Sendable>: Equatable, Sendable {
    case absent
    case null
    case value(T)

    public var valueOrNil: T? {
        if case .value(let v) = self { return v }
        return nil
    }

    /// True when the document says something about this key (set or clear).
    public var isSpecified: Bool {
        if case .absent = self { return false }
        return true
    }
}

extension KeyedDecodingContainer {
    func configField<T: Decodable & Equatable & Sendable>(
        _ type: T.Type, forKey key: Key
    ) throws -> ConfigField<T> {
        guard contains(key) else { return .absent }
        if try decodeNil(forKey: key) { return .null }
        return .value(try decode(T.self, forKey: key))
    }
}

extension KeyedEncodingContainer {
    mutating func encode<T: Encodable & Equatable & Sendable>(
        configField field: ConfigField<T>, forKey key: Key
    ) throws {
        switch field {
        case .absent: break
        case .null: try encodeNil(forKey: key)
        case .value(let v): try encode(v, forKey: key)
        }
    }
}

// MARK: - Section identifiers

/// Every top-level section of the document, in canonical render order.
/// Server runtime settings are Settings-UI-only (`server` was removed in
/// scope reduction 2). `model_defaults`, `chat`, and `app` cover a small
/// set of everyday switches; the rest of those pages stays in the UI.
public enum ConfigSectionID: String, CaseIterable, Sendable {
    case memory
    case harnessRuntimes = "harness_runtimes"
    case defaultAgent = "default_agent"
    /// The built-in helper behind Osaurus questions and settings changes.
    case configurator
    /// Which agent NEW chats open with. `active_agent` is accepted as a
    /// legacy alias on input.
    case activeAgent = "new_chat_agent"
    case modelDefaults = "model_defaults"
    case chat
    case app
    case agents
    case tools
    case delegation
    case commands
    case knowledgeCollections = "knowledge_collections"
    case channels
    case mcpServers = "mcp_servers"
    case models
    case plugins
    case providers
    case searchProviders = "search_providers"
    /// Automations: schedules, folder watchers, webhooks and channel
    /// message routing. `events` / `schedules` / `watchers` are accepted as
    /// legacy aliases.
    case automations

    public static var allNames: [String] { allCases.map { $0.rawValue } }

    /// Case-insensitive lookup that also accepts legacy section spellings
    /// (`active_agent` → `.activeAgent`, `events` / `schedules` / `watchers` →
    /// `.automations`).
    public static func parse(_ raw: String) -> ConfigSectionID? {
        let lowered = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let id = ConfigSectionID(rawValue: lowered) { return id }
        if lowered == OsaurusConfigDocument.legacyNewChatAgentKey { return .activeAgent }
        if OsaurusConfigDocument.legacyEventSectionKeys.contains(lowered) { return .automations }
        return nil
    }
}

// MARK: - Document

public struct OsaurusConfigDocument: Equatable, Sendable {
    /// Schema version. Currently always 1.
    public var version: Int?
    public var memory: MemorySection?
    /// Registered harness runtimes (Claude Code, Pi, Pi-based CLIs).
    public var harnessRuntimes: [HarnessRuntimeEntry]?
    public var defaultAgent: DefaultAgentSection?
    public var configurator: ConfiguratorSection?
    /// Name of the agent NEW chats open with ("default" or a custom agent's
    /// name). Serialized as `new_chat_agent`; `active_agent` still decodes.
    public var activeAgent: String?
    public var modelDefaults: ModelDefaultsSection?
    public var chat: ChatSection?
    public var app: AppSection?
    public var agents: [AgentEntry]?
    public var tools: ToolsSection?
    public var delegation: DelegationSection?
    public var commands: [CommandEntry]?
    public var knowledgeCollections: [KnowledgeCollectionEntry]?
    public var channels: ChannelsSection?
    public var mcpServers: [MCPServerEntry]?
    /// Desired installed local MLX models (Hugging Face repo ids).
    public var models: [String]?
    /// Desired installed plugins (registry plugin ids, e.g. `osaurus.weather`).
    public var plugins: [String]?
    public var providers: [ProviderEntry]?
    public var searchProviders: SearchProvidersSection?
    /// Serialized as `automations`; the pre-rename `events` key still decodes.
    public var automations: [EventEntry]?
    /// Legacy `schedules:` input; folded into `automations` before planning.
    public var legacySchedules: [ScheduleEntry]?
    /// Legacy `watchers:` input; folded into `automations` before planning.
    public var legacyWatchers: [WatcherEntry]?

    public init() {}

    /// Section ids present in this document.
    public var declaredSections: [ConfigSectionID] {
        var out: [ConfigSectionID] = []
        if memory != nil { out.append(.memory) }
        if harnessRuntimes != nil { out.append(.harnessRuntimes) }
        if defaultAgent != nil { out.append(.defaultAgent) }
        if configurator != nil { out.append(.configurator) }
        if activeAgent != nil { out.append(.activeAgent) }
        if modelDefaults != nil { out.append(.modelDefaults) }
        if chat != nil { out.append(.chat) }
        if app != nil { out.append(.app) }
        if agents != nil { out.append(.agents) }
        if tools != nil { out.append(.tools) }
        if delegation != nil { out.append(.delegation) }
        if commands != nil { out.append(.commands) }
        if knowledgeCollections != nil { out.append(.knowledgeCollections) }
        if channels != nil { out.append(.channels) }
        if mcpServers != nil { out.append(.mcpServers) }
        if models != nil { out.append(.models) }
        if plugins != nil { out.append(.plugins) }
        if providers != nil { out.append(.providers) }
        if searchProviders != nil { out.append(.searchProviders) }
        if automations != nil || legacySchedules != nil || legacyWatchers != nil { out.append(.automations) }
        return out
    }

    /// Copy containing only the given sections (used by filtered export).
    public func filtered(to sections: Set<ConfigSectionID>) -> OsaurusConfigDocument {
        var doc = OsaurusConfigDocument()
        doc.version = version
        if sections.contains(.memory) { doc.memory = memory }
        if sections.contains(.harnessRuntimes) { doc.harnessRuntimes = harnessRuntimes }
        if sections.contains(.defaultAgent) { doc.defaultAgent = defaultAgent }
        if sections.contains(.configurator) { doc.configurator = configurator }
        if sections.contains(.activeAgent) { doc.activeAgent = activeAgent }
        if sections.contains(.modelDefaults) { doc.modelDefaults = modelDefaults }
        if sections.contains(.chat) { doc.chat = chat }
        if sections.contains(.app) { doc.app = app }
        if sections.contains(.agents) { doc.agents = agents }
        if sections.contains(.tools) { doc.tools = tools }
        if sections.contains(.delegation) { doc.delegation = delegation }
        if sections.contains(.commands) { doc.commands = commands }
        if sections.contains(.knowledgeCollections) { doc.knowledgeCollections = knowledgeCollections }
        if sections.contains(.channels) { doc.channels = channels }
        if sections.contains(.mcpServers) { doc.mcpServers = mcpServers }
        if sections.contains(.models) { doc.models = models }
        if sections.contains(.plugins) { doc.plugins = plugins }
        if sections.contains(.providers) { doc.providers = providers }
        if sections.contains(.searchProviders) { doc.searchProviders = searchProviders }
        if sections.contains(.automations) {
            doc.automations = automations
            doc.legacySchedules = legacySchedules
            doc.legacyWatchers = legacyWatchers
        }
        return doc
    }
}

extension OsaurusConfigDocument: Codable {
    enum CodingKeys: String, CodingKey {
        case version
        case memory
        case harnessRuntimes = "harness_runtimes"
        case defaultAgent = "default_agent"
        case configurator
        case activeAgent = "new_chat_agent"
        /// Legacy spelling, read-only: older documents and habits.
        case legacyActiveAgent = "active_agent"
        case modelDefaults = "model_defaults"
        case chat, app
        case agents, tools
        case delegation
        case commands
        case knowledgeCollections = "knowledge_collections"
        case channels
        case mcpServers = "mcp_servers"
        case models, plugins, providers
        case searchProviders = "search_providers"
        case automations
        /// Pre-rename spelling, read-only.
        case legacyEvents = "events"
        case legacySchedules = "schedules"
        case legacyWatchers = "watchers"
    }

    /// Alias for the legacy key on input documents (validation accepts it
    /// too; see `ConfigYAML.checkMapping`).
    public static let legacyNewChatAgentKey = "active_agent"
    /// Pre-automations section keys, still accepted on input.
    public static let legacyEventSectionKeys: Set<String> = ["events", "schedules", "watchers"]

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version)
        memory = try c.decodeIfPresent(MemorySection.self, forKey: .memory)
        harnessRuntimes = try c.decodeIfPresent([HarnessRuntimeEntry].self, forKey: .harnessRuntimes)
        defaultAgent = try c.decodeIfPresent(DefaultAgentSection.self, forKey: .defaultAgent)
        configurator = try c.decodeIfPresent(ConfiguratorSection.self, forKey: .configurator)
        activeAgent =
            try c.decodeIfPresent(String.self, forKey: .activeAgent)
            ?? c.decodeIfPresent(String.self, forKey: .legacyActiveAgent)
        modelDefaults = try c.decodeIfPresent(ModelDefaultsSection.self, forKey: .modelDefaults)
        chat = try c.decodeIfPresent(ChatSection.self, forKey: .chat)
        app = try c.decodeIfPresent(AppSection.self, forKey: .app)
        agents = try c.decodeIfPresent([AgentEntry].self, forKey: .agents)
        tools = try c.decodeIfPresent(ToolsSection.self, forKey: .tools)
        delegation = try c.decodeIfPresent(DelegationSection.self, forKey: .delegation)
        commands = try c.decodeIfPresent([CommandEntry].self, forKey: .commands)
        knowledgeCollections = try c.decodeIfPresent(
            [KnowledgeCollectionEntry].self, forKey: .knowledgeCollections)
        channels = try c.decodeIfPresent(ChannelsSection.self, forKey: .channels)
        mcpServers = try c.decodeIfPresent([MCPServerEntry].self, forKey: .mcpServers)
        models = try c.decodeIfPresent([String].self, forKey: .models)
        plugins = try c.decodeIfPresent([String].self, forKey: .plugins)
        providers = try c.decodeIfPresent([ProviderEntry].self, forKey: .providers)
        searchProviders = try c.decodeIfPresent(SearchProvidersSection.self, forKey: .searchProviders)
        automations =
            try c.decodeIfPresent([EventEntry].self, forKey: .automations)
            ?? c.decodeIfPresent([EventEntry].self, forKey: .legacyEvents)
        legacySchedules = try c.decodeIfPresent([ScheduleEntry].self, forKey: .legacySchedules)
        legacyWatchers = try c.decodeIfPresent([WatcherEntry].self, forKey: .legacyWatchers)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(version, forKey: .version)
        try c.encodeIfPresent(memory, forKey: .memory)
        try c.encodeIfPresent(harnessRuntimes, forKey: .harnessRuntimes)
        try c.encodeIfPresent(defaultAgent, forKey: .defaultAgent)
        try c.encodeIfPresent(configurator, forKey: .configurator)
        try c.encodeIfPresent(activeAgent, forKey: .activeAgent)
        try c.encodeIfPresent(modelDefaults, forKey: .modelDefaults)
        try c.encodeIfPresent(chat, forKey: .chat)
        try c.encodeIfPresent(app, forKey: .app)
        try c.encodeIfPresent(agents, forKey: .agents)
        try c.encodeIfPresent(tools, forKey: .tools)
        try c.encodeIfPresent(delegation, forKey: .delegation)
        try c.encodeIfPresent(commands, forKey: .commands)
        try c.encodeIfPresent(knowledgeCollections, forKey: .knowledgeCollections)
        try c.encodeIfPresent(channels, forKey: .channels)
        try c.encodeIfPresent(mcpServers, forKey: .mcpServers)
        try c.encodeIfPresent(models, forKey: .models)
        try c.encodeIfPresent(plugins, forKey: .plugins)
        try c.encodeIfPresent(providers, forKey: .providers)
        try c.encodeIfPresent(searchProviders, forKey: .searchProviders)
        try c.encodeIfPresent(automations, forKey: .automations)
        try c.encodeIfPresent(legacySchedules, forKey: .legacySchedules)
        try c.encodeIfPresent(legacyWatchers, forKey: .legacyWatchers)
    }
}

// MARK: - Removed sections (scope reduction 2)
//
// `ServerSection` was deleted: server runtime tuning is in flux (parameters
// may become per-model). See docs/config-parity-audit.md.

// MARK: - Model defaults

/// The model roles on Models → Model Defaults. Values use the
/// `default_agent.model` reference format; null clears the role.
public struct ModelDefaultsSection: Equatable, Sendable {
    /// Background work: memory, chat titles, follow-ups, transcription
    /// cleanup. Null falls back to the chat's model.
    public var coreModel: ConfigField<String> = .absent
    /// Summarizes older messages near the context limit. Null falls back
    /// to the chat's model.
    public var compactionModel: ConfigField<String> = .absent
    public init() {}
}

extension ModelDefaultsSection: Codable {
    enum CodingKeys: String, CodingKey {
        case coreModel = "core_model"
        case compactionModel = "compaction_model"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        coreModel = try c.configField(String.self, forKey: .coreModel)
        compactionModel = try c.configField(String.self, forKey: .compactionModel)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(configField: coreModel, forKey: .coreModel)
        try c.encode(configField: compactionModel, forKey: .compactionModel)
    }
}

// MARK: - Chat

/// Everyday switches from the Chat settings page. Sampling, tool attempts,
/// and the context cap stay in the Settings UI.
public struct ChatSection: Codable, Equatable, Sendable {
    public var smoothStreaming: Bool?
    /// Group Thinking & Tool Activity.
    public var groupActivity: Bool?
    /// Expand Thinking While Streaming.
    public var expandThinking: Bool?
    public var spellCheck: Bool?
    /// Automatically Name Chats.
    public var autoTitles: Bool?
    public var followUpSuggestions: Bool?
    public var clipboardMonitoring: Bool?
    /// Keep Mac Awake While Agents Run.
    public var keepMacAwake: Bool?

    /// `UserDefaults` keys shared with the `@AppStorage` switches on the
    /// Chat page and their runtime readers.
    static let smoothStreamingKey = "chatSmoothStreamingEnabled"
    static let expandThinkingKey = "chatExpandThinkingWhileStreamingEnabled"

    /// Every `UserDefaults` key an apply of this section writes, for callers
    /// that snapshot and restore them (the eval runner).
    public static var userDefaultsKeys: [String] {
        [
            smoothStreamingKey, expandThinkingKey, ComposerSpellCheckSetting.defaultsKey,
            ContentBlock.ActivityRollupSetting.defaultsKey, AgentRunPowerManager.keepAwakeDefaultsKey,
        ]
    }

    public init() {}

    enum CodingKeys: String, CodingKey {
        case smoothStreaming = "smooth_streaming"
        case groupActivity = "group_activity"
        case expandThinking = "expand_thinking"
        case spellCheck = "spell_check"
        case autoTitles = "auto_titles"
        case followUpSuggestions = "follow_up_suggestions"
        case clipboardMonitoring = "clipboard_monitoring"
        case keepMacAwake = "keep_mac_awake"
    }
}

// MARK: - App

/// App basics from the General settings page.
public struct AppSection: Equatable, Sendable {
    /// Global hotkey as text (`cmd+shift+o`, see `HotkeyText`); null
    /// turns the hotkey off.
    public var hotkey: ConfigField<String> = .absent
    public var startAtLogin: Bool?
    public var showNotifications: Bool?
    public init() {}
}

extension AppSection: Codable {
    enum CodingKeys: String, CodingKey {
        case hotkey
        case startAtLogin = "start_at_login"
        case showNotifications = "show_notifications"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        hotkey = try c.configField(String.self, forKey: .hotkey)
        startAtLogin = try c.decodeIfPresent(Bool.self, forKey: .startAtLogin)
        showNotifications = try c.decodeIfPresent(Bool.self, forKey: .showNotifications)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(configField: hotkey, forKey: .hotkey)
        try c.encodeIfPresent(startAtLogin, forKey: .startAtLogin)
        try c.encodeIfPresent(showNotifications, forKey: .showNotifications)
    }
}

// MARK: - Memory

public struct MemorySection: Codable, Equatable, Sendable {
    public var enabled: Bool?
    /// 100...4000
    public var budgetTokens: Int?
    /// 0...3650; 0 keeps episodes forever.
    public var retentionDays: Int?

    public init() {}

    enum CodingKeys: String, CodingKey {
        case enabled
        case budgetTokens = "budget_tokens"
        case retentionDays = "retention_days"
    }
}

// MARK: - Default agent

public struct DefaultAgentSection: Equatable, Sendable {
    /// Custom display name for the built-in Orchestrator agent; null
    /// clears back to the stock "Osaurus" name. Cosmetic only.
    public var name: ConfigField<String> = .absent
    /// Installed local model id or `provider/model`; null falls back to the
    /// first available installed local model.
    public var model: ConfigField<String> = .absent
    public var temperature: ConfigField<Double> = .absent
    public var maxTokens: ConfigField<Int> = .absent
    /// The Default agent's persona (system prompt).
    public var systemPrompt: String?
    /// `builtin` or a registered harness runtime's name.
    public var runtime: String?
    public var claudeCode: AgentClaudeCodeEntry?
    public init() {}
}

extension DefaultAgentSection: Codable {
    enum CodingKeys: String, CodingKey {
        case name, model, temperature
        case maxTokens = "max_tokens"
        case systemPrompt = "system_prompt"
        case runtime
        case claudeCode = "claude_code"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.configField(String.self, forKey: .name)
        model = try c.configField(String.self, forKey: .model)
        temperature = try c.configField(Double.self, forKey: .temperature)
        maxTokens = try c.configField(Int.self, forKey: .maxTokens)
        systemPrompt = try c.decodeIfPresent(String.self, forKey: .systemPrompt)
        runtime = try c.decodeIfPresent(String.self, forKey: .runtime)
        claudeCode = try c.decodeIfPresent(AgentClaudeCodeEntry.self, forKey: .claudeCode)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(configField: name, forKey: .name)
        try c.encode(configField: model, forKey: .model)
        try c.encode(configField: temperature, forKey: .temperature)
        try c.encode(configField: maxTokens, forKey: .maxTokens)
        try c.encodeIfPresent(systemPrompt, forKey: .systemPrompt)
        try c.encodeIfPresent(runtime, forKey: .runtime)
        try c.encodeIfPresent(claudeCode, forKey: .claudeCode)
    }
}

// MARK: - Configurator

/// Settings → Agents → Configurator. The name is fixed, so it has no key.
public struct ConfiguratorSection: Equatable, Sendable {
    /// Model reference in the `default_agent.model` format; null uses the
    /// Orchestrator's model.
    public var model: ConfigField<String> = .absent
    /// 0...2; null uses the model's own default.
    public var temperature: ConfigField<Double> = .absent
    /// Extra instructions added after the built-in ones.
    public var systemPrompt: String?
    public init() {}
}

extension ConfiguratorSection: Codable {
    enum CodingKeys: String, CodingKey {
        case model, temperature
        case systemPrompt = "system_prompt"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        model = try c.configField(String.self, forKey: .model)
        temperature = try c.configField(Double.self, forKey: .temperature)
        systemPrompt = try c.decodeIfPresent(String.self, forKey: .systemPrompt)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(configField: model, forKey: .model)
        try c.encode(configField: temperature, forKey: .temperature)
        try c.encodeIfPresent(systemPrompt, forKey: .systemPrompt)
    }
}

// MARK: - Custom agents

public struct AgentCapabilitiesEntry: Codable, Equatable, Sendable {
    public var toolsEnabled: Bool?
    public var memoryEnabled: Bool?
    public var searchMemoryEnabled: Bool?
    public var webSearchEnabled: Bool?
    public var knowledgeEnabled: Bool?
    /// Knowledge collection UUIDs (replaces the grant list).
    public var knowledgeCollectionIds: [String]?
    public var dbEnabled: Bool?
    public var selfSchedulingEnabled: Bool?
    public var computerUseEnabled: Bool?
    public var browserUseEnabled: Bool?
    /// Image generation/editing on this agent (`AgentSettings.imageEnabled`).
    /// Image lives on custom agents only; the Orchestrator delegates to one.
    public var imageEnabled: Bool?
    /// AppleScript / `mac_query` on this agent
    /// (`AgentSettings.appleScriptEnabled`). Custom agents only, as above.
    public var applescriptEnabled: Bool?
    public var speakEnabled: Bool?
    public var renderChartEnabled: Bool?
    /// Whether the relay tunnel forwards to this agent (Wave 3b).
    public var relayEnabled: Bool?
    /// Built-in Apple app tool families enabled on this agent
    /// (`AgentSettings.enabledAppleApps`): `calendar`, `reminders`,
    /// `contacts`, `notes`, `mail`, `messages`, `maps`, `music`,
    /// `shortcuts`. The provided list REPLACES the set (`[]` disables all).
    /// Custom agents only — the Orchestrator configures these, never calls
    /// them.
    public var appleApps: [String]?
    /// `calculate` (exact arithmetic) on this agent.
    public var calculatorEnabled: Bool?
    /// `detect_pii` / `redact_file` in this agent's host-folder chats.
    public var redactionToolsEnabled: Bool?
    /// `todo` + `complete` on this agent.
    public var taskChecklistEnabled: Bool?
    /// `clarify` on this agent.
    public var clarifyEnabled: Bool?
    /// `share_artifact` on this agent.
    public var artifactsEnabled: Bool?

    public init() {}

    enum CodingKeys: String, CodingKey, CaseIterable {
        case toolsEnabled = "tools_enabled"
        case memoryEnabled = "memory_enabled"
        case searchMemoryEnabled = "search_memory_enabled"
        case webSearchEnabled = "web_search_enabled"
        case knowledgeEnabled = "knowledge_enabled"
        case knowledgeCollectionIds = "knowledge_collection_ids"
        case dbEnabled = "db_enabled"
        case selfSchedulingEnabled = "self_scheduling_enabled"
        case computerUseEnabled = "computer_use_enabled"
        case browserUseEnabled = "browser_use_enabled"
        case imageEnabled = "image_enabled"
        case applescriptEnabled = "applescript_enabled"
        case speakEnabled = "speak_enabled"
        case renderChartEnabled = "render_chart_enabled"
        case relayEnabled = "relay_enabled"
        case appleApps = "apple_apps"
        case calculatorEnabled = "calculator_enabled"
        case redactionToolsEnabled = "redaction_tools_enabled"
        case taskChecklistEnabled = "task_checklist_enabled"
        case clarifyEnabled = "clarify_enabled"
        case artifactsEnabled = "artifacts_enabled"
    }
}

/// Per-agent tool selection. `mode` is `auto` (RAG-picked) or `manual`.
/// `enabled` lists the tool names an agent may call in manual mode. Tools
/// owned by an MCP server or plugin are declared through `mcp_servers` /
/// `plugins` instead, so a document stays portable across machines where
/// the server exposes a different tool set.
public struct AgentToolsEntry: Codable, Equatable, Sendable {
    public var mode: String?
    public var enabled: [String]?

    public init() {}
}

/// Named group enablement (MCP servers by name, plugins by registry id).
/// `enabled` adds every tool the group owns to the agent's manual list,
/// `disabled` removes them. Groups not listed are untouched.
public struct AgentToolGroupsEntry: Codable, Equatable, Sendable {
    public var enabled: [String]?
    public var disabled: [String]?

    public init() {}
}

/// Sandbox (autonomous code execution) knobs for one agent.
public struct AgentSandboxEntry: Codable, Equatable, Sendable {
    public var enabled: Bool?
    public var networkEnabled: Bool?
    public var allowedDomains: [String]?
    public var maxCommandsPerTurn: Int?
    public var backgroundProcessEnabled: Bool?
    public var pluginCreate: Bool?

    public init() {}

    enum CodingKeys: String, CodingKey {
        case enabled
        case networkEnabled = "network_enabled"
        case allowedDomains = "allowed_domains"
        case maxCommandsPerTurn = "max_commands_per_turn"
        case backgroundProcessEnabled = "background_process_enabled"
        case pluginCreate = "plugin_create"
    }
}

/// Subagent delegation for one agent. `agents` are agent names (resolved
/// to local ids on apply).
public struct AgentSubagentsEntry: Codable, Equatable, Sendable {
    public var enabled: Bool?
    public var agents: [String]?
    /// Deprecated and ignored. Spawning by raw model id was removed, but
    /// templates exported before that still carry the key, so it keeps
    /// decoding instead of failing the strict validator.
    public var models: [String]?

    public init() {}
}

/// A custom agent. Matched to existing agents by `name` (case-insensitive);
/// an unmatched entry is created, a matched one is patched.
public struct AgentEntry: Equatable, Sendable {
    public var name: String
    /// Optional `AgentStarterTemplate` id (`coder`, `researcher`, `writer`,
    /// `assistant`, `productivity`): seeds an omitted system prompt and,
    /// when the entry has no `description`, its routing description.
    public var template: String?
    /// Optional. A blank description is valid; Osaurus generates a routing
    /// summary from the system prompt in the background when one is missing.
    public var description: String?
    public var systemPrompt: String?
    /// Bundled mascot id (`AgentMascot`). Empty string clears it back to
    /// the name's initial; absent preserves it.
    public var avatar: String?
    public var model: ConfigField<String> = .absent
    /// `true` locks chats to `model` (`Agent.modelLocked`); absent preserves it.
    public var modelLocked: Bool?
    public var temperature: ConfigField<Double> = .absent
    public var maxTokens: ConfigField<Int> = .absent
    /// Replaces the advanced override group; null clears it, absent preserves it.
    public var generationSettings: ConfigField<AgentGenerationSettings> = .absent
    /// Omission preserves the current display choice; explicit false disables it.
    public var showResponseMetrics: Bool?
    /// `false` hides follow-up suggestions in this agent's chats
    /// (`AgentFollowUpConfig.enabled`); absent preserves the current choice.
    public var followUpSuggestions: Bool?
    public var capabilities: AgentCapabilitiesEntry?
    public var tools: AgentToolsEntry?
    public var mcpServers: AgentToolGroupsEntry?
    public var plugins: AgentToolGroupsEntry?
    /// Skill allow-list (`Agent.skillNames`) by name or slug. A list
    /// replaces the set; explicit `null` lets the agent see every skill.
    public var skills: ConfigField<[String]> = .absent
    /// Plugin id → extra instructions injected when that plugin's tools load.
    public var pluginInstructions: [String: String]?
    public var sandbox: AgentSandboxEntry?
    public var subagents: AgentSubagentsEntry?
    /// Working folder PATH. Exported as a hint only (never the bookmark).
    /// On apply the folder is attached when it exists locally and a
    /// security-scoped bookmark can be minted; otherwise the result asks
    /// the user to pick it. Explicit `null` detaches the folder.
    public var workingFolder: ConfigField<String> = .absent
    /// `true` makes the working folder read only
    /// (`AgentSettings.workingFolderReadOnly`); absent preserves it.
    public var workingFolderReadOnly: Bool?
    /// Provenance: the agent template this agent was created from.
    public var sourceTemplate: String?
    /// Installed workflow names this agent gets as `workflow_<slug>` tools.
    /// The list replaces the agent's set; `[]` turns them all off.
    public var workflows: [String]?
    /// `builtin` or a registered harness runtime's name.
    public var runtime: String?
    public var claudeCode: AgentClaudeCodeEntry?
    /// What an `.ask` tool does when someone other than the owner drives
    /// this shared agent: `deny` (default) or `ask_owner`.
    public var sharedToolApproval: SharedToolApprovalPolicy?
    /// Read only when the entry creates the agent: `false` keeps the new
    /// agent out of the Orchestrator's spawn pool. Patching an existing
    /// agent ignores it, so the user's Settings → Subagents choice stays.
    public var orchestratorSpawnable: Bool?

    public init(name: String) {
        self.name = name
    }
}

extension AgentEntry: Codable {
    enum CodingKeys: String, CodingKey {
        case name, template, description
        case systemPrompt = "system_prompt"
        case avatar
        case model, temperature
        case modelLocked = "model_locked"
        case maxTokens = "max_tokens"
        case generationSettings = "generation_settings"
        case showResponseMetrics = "show_response_metrics"
        case followUpSuggestions = "follow_up_suggestions"
        case capabilities
        case tools
        case mcpServers = "mcp_servers"
        case plugins
        case skills
        case pluginInstructions = "plugin_instructions"
        case sandbox
        case subagents
        case workingFolder = "working_folder"
        case workingFolderReadOnly = "working_folder_read_only"
        case sourceTemplate = "source_template"
        case workflows
        case runtime
        case claudeCode = "claude_code"
        case sharedToolApproval = "shared_tool_approval"
        case orchestratorSpawnable = "orchestrator_spawnable"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        template = try c.decodeIfPresent(String.self, forKey: .template)
        description = try c.decodeIfPresent(String.self, forKey: .description)
        systemPrompt = try c.decodeIfPresent(String.self, forKey: .systemPrompt)
        avatar = try c.decodeIfPresent(String.self, forKey: .avatar)
        model = try c.configField(String.self, forKey: .model)
        modelLocked = try c.decodeIfPresent(Bool.self, forKey: .modelLocked)
        temperature = try c.configField(Double.self, forKey: .temperature)
        maxTokens = try c.configField(Int.self, forKey: .maxTokens)
        generationSettings = try c.configField(AgentGenerationSettings.self, forKey: .generationSettings)
        showResponseMetrics = try c.decodeIfPresent(Bool.self, forKey: .showResponseMetrics)
        followUpSuggestions = try c.decodeIfPresent(Bool.self, forKey: .followUpSuggestions)
        capabilities = try c.decodeIfPresent(AgentCapabilitiesEntry.self, forKey: .capabilities)
        tools = try c.decodeIfPresent(AgentToolsEntry.self, forKey: .tools)
        mcpServers = try c.decodeIfPresent(AgentToolGroupsEntry.self, forKey: .mcpServers)
        plugins = try c.decodeIfPresent(AgentToolGroupsEntry.self, forKey: .plugins)
        skills = try c.configField([String].self, forKey: .skills)
        pluginInstructions = try c.decodeIfPresent([String: String].self, forKey: .pluginInstructions)
        sandbox = try c.decodeIfPresent(AgentSandboxEntry.self, forKey: .sandbox)
        subagents = try c.decodeIfPresent(AgentSubagentsEntry.self, forKey: .subagents)
        workingFolder = try c.configField(String.self, forKey: .workingFolder)
        workingFolderReadOnly = try c.decodeIfPresent(Bool.self, forKey: .workingFolderReadOnly)
        sourceTemplate = try c.decodeIfPresent(String.self, forKey: .sourceTemplate)
        workflows = try c.decodeIfPresent([String].self, forKey: .workflows)
        runtime = try c.decodeIfPresent(String.self, forKey: .runtime)
        claudeCode = try c.decodeIfPresent(AgentClaudeCodeEntry.self, forKey: .claudeCode)
        sharedToolApproval = try c.decodeIfPresent(SharedToolApprovalPolicy.self, forKey: .sharedToolApproval)
        orchestratorSpawnable = try c.decodeIfPresent(Bool.self, forKey: .orchestratorSpawnable)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(name, forKey: .name)
        try c.encodeIfPresent(template, forKey: .template)
        try c.encodeIfPresent(description, forKey: .description)
        try c.encodeIfPresent(systemPrompt, forKey: .systemPrompt)
        try c.encodeIfPresent(avatar, forKey: .avatar)
        try c.encode(configField: model, forKey: .model)
        try c.encodeIfPresent(modelLocked, forKey: .modelLocked)
        try c.encode(configField: temperature, forKey: .temperature)
        try c.encode(configField: maxTokens, forKey: .maxTokens)
        try c.encode(configField: generationSettings, forKey: .generationSettings)
        try c.encodeIfPresent(showResponseMetrics, forKey: .showResponseMetrics)
        try c.encodeIfPresent(followUpSuggestions, forKey: .followUpSuggestions)
        try c.encodeIfPresent(capabilities, forKey: .capabilities)
        try c.encodeIfPresent(tools, forKey: .tools)
        try c.encodeIfPresent(mcpServers, forKey: .mcpServers)
        try c.encodeIfPresent(plugins, forKey: .plugins)
        try c.encode(configField: skills, forKey: .skills)
        try c.encodeIfPresent(pluginInstructions, forKey: .pluginInstructions)
        try c.encodeIfPresent(sandbox, forKey: .sandbox)
        try c.encodeIfPresent(subagents, forKey: .subagents)
        try c.encode(configField: workingFolder, forKey: .workingFolder)
        try c.encodeIfPresent(workingFolderReadOnly, forKey: .workingFolderReadOnly)
        try c.encodeIfPresent(sourceTemplate, forKey: .sourceTemplate)
        try c.encodeIfPresent(workflows, forKey: .workflows)
        try c.encodeIfPresent(runtime, forKey: .runtime)
        try c.encodeIfPresent(claudeCode, forKey: .claudeCode)
        try c.encodeIfPresent(sharedToolApproval, forKey: .sharedToolApproval)
        try c.encodeIfPresent(orchestratorSpawnable, forKey: .orchestratorSpawnable)
    }
}

// MARK: - Tools

public struct ToolsSection: Codable, Equatable, Sendable {
    /// Tool name → enabled. Only the listed tools change.
    public var enabled: [String: Bool]?
    /// Tool name → permission policy (auto | ask | deny). Setting `auto`
    /// is a high-risk change and always requires explicit user approval.
    public var policies: [String: String]?

    public init() {}

    enum CodingKeys: String, CodingKey {
        case enabled, policies
    }
}

// MARK: - MCP servers

/// A user-added MCP server (HTTP or stdio). Matched by `name`
/// (case-insensitive). Plugin-owned servers stay with their plugin.
/// Adding or changing a stdio command is HIGH RISK — it launches a local
/// subprocess.
public struct MCPServerEntry: Codable, Equatable, Sendable {
    public var name: String
    /// One of: http (default), stdio. Immutable after create.
    public var transport: String?
    /// HTTP transport only.
    public var url: String?
    /// One of: none, bearer, oauth (HTTP only). Secrets never travel
    /// through the document — a keyed server is registered and the user
    /// finishes auth in Settings → Tools & MCP → Services.
    public var auth: String?
    public var enabled: Bool?
    /// stdio transport: the executable to launch. Required to create.
    public var command: String?
    public var args: [String]?
    /// Plain (non-secret) environment. Secret env values are Keychain-only
    /// and are set in Settings; they never appear here.
    public var env: [String: String]?
    public var workingDirectory: String?
    /// One of: sandbox (default), host. Running on the host is HIGH RISK.
    public var executionHost: String?
    /// Write-only secret reference (env:VAR or keychain:service/account) for
    /// the HTTP bearer token. Resolved at apply, stored in the Keychain,
    /// never exported.
    public var tokenRef: String?
    /// Write-only map of stdio env KEY -> secret reference. Each value is
    /// resolved at apply and stored in the Keychain; the key joins
    /// `secretEnvKeys` and leaves the plain env. Never exported.
    public var secretEnvRefs: [String: String]?
    /// Write-only map of HTTP request header -> secret reference, for
    /// servers keyed by a custom header such as `X-API-Key`. Each value is
    /// resolved at apply and stored in the Keychain; the header joins
    /// `secretHeaderKeys`. Never exported.
    public var secretHeaderRefs: [String: String]?

    public init(name: String) {
        self.name = name
    }

    enum CodingKeys: String, CodingKey {
        case name, transport, url, auth, enabled, command, args, env
        case workingDirectory = "working_directory"
        case executionHost = "execution_host"
        case tokenRef = "token_ref"
        case secretEnvRefs = "secret_env_refs"
        case secretHeaderRefs = "secret_header_refs"
    }
}

// MARK: - Cloud providers

/// A cloud LLM provider. Matched by `name` (case-insensitive). Creating a
/// new provider opens the native credential sheet during apply — the
/// document itself never carries a key or token.
public struct ProviderEntry: Equatable, Sendable {
    public var name: String
    /// Preset id (anthropic, openai, codex_oauth, azure_openai, google, xai,
    /// deepseek, venice, openrouter, ollama, custom, osaurus_agent).
    /// Required to create; immutable after (recreate to change).
    public var provider: String?
    public var enabled: Bool?
    public var autoConnect: Bool?
    /// Request flag, not state: `true` opens the secure credential sheet
    /// during apply so the user can set or rotate this provider's key/token —
    /// even when the provider already has working credentials (e.g. switching
    /// from OAuth to an API key). The secret itself never appears in the
    /// document; the flag is write-only and never exported.
    public var setApiKey: Bool?
    /// Write-only secret reference (env:VAR or keychain:service/account) for
    /// the API key — the non-interactive alternative to `set_api_key`.
    /// Resolved at apply, stored in the Keychain, never exported. Mutually
    /// exclusive with `set_api_key`.
    public var apiKeyRef: String?

    // Endpoint (Wave 3c). Exported for visibility; changing the endpoint
    // of an EXISTING provider is refused (the classic bait-and-switch under
    // a stored credential — recreate instead). On create they override the
    // preset's defaults, which is how a `custom` provider gets its host.
    public var host: String?
    /// One of: http, https. Create-only.
    public var providerProtocol: String?
    /// Create-only; null uses the protocol default (80/443).
    public var port: ConfigField<Int> = .absent
    /// Create-only (e.g. "/v1").
    public var basePath: String?

    // Mutable non-credential connection settings (Wave 3c).
    /// 1..600 seconds.
    public var timeoutSeconds: Double?
    public var disableTimeout: Bool?
    /// Model ids pinned alongside discovery (Azure deployments live here).
    /// Replaces the list.
    public var manualModelIds: [String]?

    public init(name: String) {
        self.name = name
    }
}

extension ProviderEntry: Codable {
    enum CodingKeys: String, CodingKey {
        case name, provider, enabled
        case autoConnect = "auto_connect"
        case setApiKey = "set_api_key"
        case apiKeyRef = "api_key_ref"
        case host
        case providerProtocol = "protocol"
        case port
        case basePath = "base_path"
        case timeoutSeconds = "timeout_seconds"
        case disableTimeout = "disable_timeout"
        case manualModelIds = "manual_model_ids"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        provider = try c.decodeIfPresent(String.self, forKey: .provider)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled)
        autoConnect = try c.decodeIfPresent(Bool.self, forKey: .autoConnect)
        setApiKey = try c.decodeIfPresent(Bool.self, forKey: .setApiKey)
        apiKeyRef = try c.decodeIfPresent(String.self, forKey: .apiKeyRef)
        host = try c.decodeIfPresent(String.self, forKey: .host)
        providerProtocol = try c.decodeIfPresent(String.self, forKey: .providerProtocol)
        port = try c.configField(Int.self, forKey: .port)
        basePath = try c.decodeIfPresent(String.self, forKey: .basePath)
        timeoutSeconds = try c.decodeIfPresent(Double.self, forKey: .timeoutSeconds)
        disableTimeout = try c.decodeIfPresent(Bool.self, forKey: .disableTimeout)
        manualModelIds = try c.decodeIfPresent([String].self, forKey: .manualModelIds)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(name, forKey: .name)
        try c.encodeIfPresent(provider, forKey: .provider)
        try c.encodeIfPresent(enabled, forKey: .enabled)
        try c.encodeIfPresent(autoConnect, forKey: .autoConnect)
        try c.encodeIfPresent(setApiKey, forKey: .setApiKey)
        try c.encodeIfPresent(apiKeyRef, forKey: .apiKeyRef)
        try c.encodeIfPresent(host, forKey: .host)
        try c.encodeIfPresent(providerProtocol, forKey: .providerProtocol)
        try c.encode(configField: port, forKey: .port)
        try c.encodeIfPresent(basePath, forKey: .basePath)
        try c.encodeIfPresent(timeoutSeconds, forKey: .timeoutSeconds)
        try c.encodeIfPresent(disableTimeout, forKey: .disableTimeout)
        try c.encodeIfPresent(manualModelIds, forKey: .manualModelIds)
    }
}

// MARK: - Search providers

public struct SearchProviderEntry: Codable, Equatable, Sendable {
    /// Catalog id (e.g. tavily, brave_api, ddg_scrape).
    public var id: String
    public var enabled: Bool?

    public init(id: String) {
        self.id = id
    }

    enum CodingKeys: String, CodingKey {
        case id, enabled
    }
}

public struct SearchProvidersSection: Codable, Equatable, Sendable {
    /// Fallback order, first = primary. Omitted providers keep their
    /// relative order after the listed ones.
    public var ranking: [String]?
    public var providers: [SearchProviderEntry]?

    public init() {}

    enum CodingKeys: String, CodingKey {
        case ranking, providers
    }
}

// MARK: - Legacy schedules / watchers (input only)

/// Legacy `schedules:` entry, translated to an `automations` entry with
/// `source.kind: schedule`. A scheduled agent run. Matched by `name` (case-insensitive). `agent`
/// references a custom agent by name (never the Default agent).
public struct ScheduleEntry: Codable, Equatable, Sendable {
    public var name: String
    /// Custom agent name that runs this schedule.
    public var agent: String?
    public var instructions: String?
    /// One of: once, every_n_minutes, hourly, daily, weekly, monthly,
    /// yearly, cron. Pair with `frequency_value` / `frequency_time_of_day`
    /// exactly like the Schedules UI.
    public var frequency: String?
    public var frequencyValue: String?
    public var frequencyTimeOfDay: String?
    public var enabled: Bool?

    public init(name: String) {
        self.name = name
    }

    enum CodingKeys: String, CodingKey {
        case name, agent, instructions, frequency
        case frequencyValue = "frequency_value"
        case frequencyTimeOfDay = "frequency_time_of_day"
        case enabled
    }
}

/// Legacy `watchers:` entry, translated to an `automations` entry with
/// `source.kind: folder`. A folder watcher. Matched by `name` (case-insensitive). `agent`
/// references a custom agent by name (never the Default agent).
public struct WatcherEntry: Codable, Equatable, Sendable {
    public var name: String
    public var agent: String?
    public var instructions: String?
    /// Absolute path of an existing directory (~ is expanded).
    public var path: String?
    public var recursive: Bool?
    /// One of: fast, balanced, patient, relaxed, deferred, extended.
    public var responsiveness: String?
    public var enabled: Bool?

    public init(name: String) {
        self.name = name
    }

    enum CodingKeys: String, CodingKey {
        case name, agent, instructions, path
        case recursive, responsiveness, enabled
    }
}
