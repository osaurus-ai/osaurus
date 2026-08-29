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
/// The `server`, `chat`, and `app` sections were removed in scope
/// reduction 2 (post-Ornith): the agent manages entities and agent-side
/// settings; machine/app settings are Settings-UI-only.
public enum ConfigSectionID: String, CaseIterable, Sendable {
    case memory
    case defaultAgent = "default_agent"
    case activeAgent = "active_agent"
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
    case schedules
    case watchers

    public static var allNames: [String] { allCases.map { $0.rawValue } }
}

// MARK: - Document

public struct OsaurusConfigDocument: Equatable, Sendable {
    /// Schema version. Currently always 1.
    public var version: Int?
    public var memory: MemorySection?
    public var defaultAgent: DefaultAgentSection?
    /// Name of the agent to make active ("default" or a custom agent's name).
    public var activeAgent: String?
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
    public var schedules: [ScheduleEntry]?
    public var watchers: [WatcherEntry]?

    public init() {}

    /// Section ids present in this document.
    public var declaredSections: [ConfigSectionID] {
        var out: [ConfigSectionID] = []
        if memory != nil { out.append(.memory) }
        if defaultAgent != nil { out.append(.defaultAgent) }
        if activeAgent != nil { out.append(.activeAgent) }
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
        if schedules != nil { out.append(.schedules) }
        if watchers != nil { out.append(.watchers) }
        return out
    }

    /// Copy containing only the given sections (used by filtered export).
    public func filtered(to sections: Set<ConfigSectionID>) -> OsaurusConfigDocument {
        var doc = OsaurusConfigDocument()
        doc.version = version
        if sections.contains(.memory) { doc.memory = memory }
        if sections.contains(.defaultAgent) { doc.defaultAgent = defaultAgent }
        if sections.contains(.activeAgent) { doc.activeAgent = activeAgent }
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
        if sections.contains(.schedules) { doc.schedules = schedules }
        if sections.contains(.watchers) { doc.watchers = watchers }
        return doc
    }
}

extension OsaurusConfigDocument: Codable {
    enum CodingKeys: String, CodingKey {
        case version
        case memory
        case defaultAgent = "default_agent"
        case activeAgent = "active_agent"
        case agents, tools
        case delegation
        case commands
        case knowledgeCollections = "knowledge_collections"
        case channels
        case mcpServers = "mcp_servers"
        case models, plugins, providers
        case searchProviders = "search_providers"
        case schedules, watchers
    }
}

// MARK: - Removed sections (scope reduction 2)
//
// `ServerSection`, `ChatSection`, and `AppSection` were deleted: server
// runtime tuning is in flux (parameters may become per-model) and chat/app
// behavior is Settings-UI-only. See docs/config-parity-audit.md.

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
    public init() {}
}

extension DefaultAgentSection: Codable {
    enum CodingKeys: String, CodingKey {
        case name, model, temperature
        case maxTokens = "max_tokens"
        case systemPrompt = "system_prompt"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.configField(String.self, forKey: .name)
        model = try c.configField(String.self, forKey: .model)
        temperature = try c.configField(Double.self, forKey: .temperature)
        maxTokens = try c.configField(Int.self, forKey: .maxTokens)
        systemPrompt = try c.decodeIfPresent(String.self, forKey: .systemPrompt)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(configField: name, forKey: .name)
        try c.encode(configField: model, forKey: .model)
        try c.encode(configField: temperature, forKey: .temperature)
        try c.encode(configField: maxTokens, forKey: .maxTokens)
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
    public var speakEnabled: Bool?
    public var renderChartEnabled: Bool?
    /// Whether the relay tunnel forwards to this agent (Wave 3b).
    public var relayEnabled: Bool?

    public init() {}

    enum CodingKeys: String, CodingKey {
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
        case speakEnabled = "speak_enabled"
        case renderChartEnabled = "render_chart_enabled"
        case relayEnabled = "relay_enabled"
    }
}

/// A custom agent. Matched to existing agents by `name` (case-insensitive);
/// an unmatched entry is created, a matched one is patched.
public struct AgentEntry: Equatable, Sendable {
    public var name: String
    public var description: String?
    public var systemPrompt: String?
    public var model: ConfigField<String> = .absent
    public var temperature: ConfigField<Double> = .absent
    public var maxTokens: ConfigField<Int> = .absent
    public var capabilities: AgentCapabilitiesEntry?

    public init(name: String) {
        self.name = name
    }
}

extension AgentEntry: Codable {
    enum CodingKeys: String, CodingKey {
        case name, description
        case systemPrompt = "system_prompt"
        case model, temperature
        case maxTokens = "max_tokens"
        case capabilities
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        description = try c.decodeIfPresent(String.self, forKey: .description)
        systemPrompt = try c.decodeIfPresent(String.self, forKey: .systemPrompt)
        model = try c.configField(String.self, forKey: .model)
        temperature = try c.configField(Double.self, forKey: .temperature)
        maxTokens = try c.configField(Int.self, forKey: .maxTokens)
        capabilities = try c.decodeIfPresent(AgentCapabilitiesEntry.self, forKey: .capabilities)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(name, forKey: .name)
        try c.encodeIfPresent(description, forKey: .description)
        try c.encodeIfPresent(systemPrompt, forKey: .systemPrompt)
        try c.encode(configField: model, forKey: .model)
        try c.encode(configField: temperature, forKey: .temperature)
        try c.encode(configField: maxTokens, forKey: .maxTokens)
        try c.encodeIfPresent(capabilities, forKey: .capabilities)
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
    /// finishes auth in Settings → Tools → Remote.
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

    public init(name: String) {
        self.name = name
    }

    enum CodingKeys: String, CodingKey {
        case name, transport, url, auth, enabled, command, args, env
        case workingDirectory = "working_directory"
        case executionHost = "execution_host"
        case tokenRef = "token_ref"
        case secretEnvRefs = "secret_env_refs"
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

// MARK: - Schedules

/// A scheduled agent run. Matched by `name` (case-insensitive). `agent`
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

// MARK: - Watchers

/// A folder watcher. Matched by `name` (case-insensitive). `agent`
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
