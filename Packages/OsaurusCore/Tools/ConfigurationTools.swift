//
//  ConfigurationTools.swift
//  osaurus
//
//  The four "always loaded" read tools the default agent uses to
//  inspect Osaurus's current configuration and explain the app:
//
//   - osaurus_status   — one-shot snapshot + suggestions
//   - osaurus_list     — list items in a scope
//   - osaurus_describe — full detail for one item
//   - osaurus_help     — bundled user-guide topics about Osaurus itself
//
//  These tools intentionally don't emit secrets. Provider rows expose
//  "has API key" booleans rather than the key itself, and `hasOAuth`
//  is exposed as a connection-status hint.
//
//  Each tool runs the same `ConfigurationToolBase.defaultAgentGateFailure`
//  check the write tools use, so reading is also default-agent-only.
//

import Foundation
import OsaurusRepository

// MARK: - Provider read visibility (eval isolation)

/// Decides which remote providers the configure READ tools surface.
///
/// Eval-only isolation: to drive a remote model (`xai/grok-4.3`,
/// `openai/gpt-5.5`, …) the eval harness connects an in-memory provider via
/// `EvalRemoteProviderBootstrap` (`addProvider(…, isEphemeral: true)`). That
/// provider lands in `configuration.providers`, so without a filter a
/// `default_agent` honesty case ("which cloud providers are connected?")
/// would read the harness's own run/judge provider and a model that
/// truthfully reports it gets scored as fabricating — the scenario's
/// "no providers connected" premise is false only because of test
/// infrastructure. When `OSAURUS_EVALS_HIDE_EPHEMERAL_PROVIDERS=1` (set by
/// the eval CLI), the reads drop ephemeral providers so the scenario sees the
/// genuine user-configured state. The eval binary runs no Bonjour discovery,
/// so in-process the only ephemeral providers are the harness's; PRODUCTION
/// never sets the flag, so Bonjour-discovered providers stay visible there.
/// Routing (`findService(forModel:)`) is untouched, so the model still runs.
enum ConfigurationProviderReadVisibility {
    static var hidesEphemeralProviders: Bool {
        ProcessInfo.processInfo.environment["OSAURUS_EVALS_HIDE_EPHEMERAL_PROVIDERS"] == "1"
    }

    /// Pure visibility filter, factored out so it is unit-testable without
    /// the `RemoteProviderManager` singleton or process env: when
    /// `hidesEphemeral` is true, drop providers for which `isEphemeral`
    /// returns true; otherwise pass everything through.
    static func filtered(
        _ providers: [RemoteProvider],
        hidesEphemeral: Bool,
        isEphemeral: (UUID) -> Bool
    ) -> [RemoteProvider] {
        guard hidesEphemeral else { return providers }
        return providers.filter { !isEphemeral($0.id) }
    }

    /// Remote providers the read tools should expose, applying the eval-only
    /// ephemeral filter.
    @MainActor
    static func visibleProviders() -> [RemoteProvider] {
        filtered(
            RemoteProviderManager.shared.configuration.providers,
            hidesEphemeral: hidesEphemeralProviders,
            isEphemeral: { RemoteProviderManager.shared.isEphemeral(id: $0) }
        )
    }

    /// Count of visible providers whose runtime state is connected.
    @MainActor
    static func connectedCount(_ providers: [RemoteProvider]) -> Int {
        providers.filter { RemoteProviderManager.shared.providerStates[$0.id]?.isConnected == true }
            .count
    }
}

private enum PluginRepositoryDiagnosticProjection {
    static func dictionary(_ result: CentralRepositoryRefreshResult?) -> [String: Any]? {
        guard let result else { return nil }
        var dict: [String: Any] = [
            "succeeded": result.succeeded,
            "repository_url": result.repositoryURL,
            "attempted_archive_urls": result.attemptedArchiveURLs,
            "cache_available": result.cacheAvailable,
        ]
        if let refreshedAt = result.refreshedAt {
            dict["refreshed_at"] = ISO8601DateFormatter().string(from: refreshedAt)
        }
        if let cacheUpdatedAt = result.cacheUpdatedAt {
            dict["cache_updated_at"] = ISO8601DateFormatter().string(from: cacheUpdatedAt)
        }
        if let failure = result.failure {
            var failureDict: [String: Any] = [
                "kind": failure.kind.rawValue,
                "message": failure.message,
                "user_message": failure.userMessage,
                "retryable": failure.retryable,
            ]
            if let failedURL = failure.failedArchiveURL {
                failureDict["failed_archive_url"] = failedURL
            }
            if let httpStatusCode = failure.httpStatusCode {
                failureDict["http_status_code"] = httpStatusCode
            }
            dict["failure"] = failureDict
        }
        return dict
    }
}

// MARK: - osaurus_status

public final class OsaurusStatusTool: OsaurusTool, @unchecked Sendable {
    public let name = "osaurus_status"
    public let description =
        "One-shot snapshot of Osaurus configuration: default agent, server, models, providers, "
        + "plugins, schedules, watchers, skills, knowledge, channels, memory, sandbox. Returns "
        + "`suggestions` derived from the snapshot — call this first when the user says "
        + "'help me set up Osaurus' or asks what's configured."
    public let parameters: JSONValue? = .object([
        "type": .string("object"),
        "additionalProperties": .bool(false),
        "properties": .object([:]),
    ])

    public init() {}

    public func execute(argumentsJSON: String) async throws -> String {
        if let gate = ConfigurationToolBase.defaultAgentGateFailure(tool: name) {
            return gate
        }

        // Skills and knowledge collections load from disk off the main
        // actor (async store APIs), so gather their counts before the hop.
        let skillCount = await SkillStore.loadAll().count
        let knowledgeCollections = await KnowledgeCollectionStore.loadAllAsync()
        let knowledgeEnabledCount = knowledgeCollections.filter { $0.isEnabled }.count
        let knowledgeTotalCount = knowledgeCollections.count

        // Build the envelope on MainActor — `[String: Any]` isn't
        // Sendable, so we serialize before returning.
        let envelope: String = await MainActor.run {
            let activeAgentId = AgentManager.shared.activeAgentId
            let activeAgent = AgentManager.shared.agent(for: activeAgentId)
            let defaultConfig = DefaultAgentConfigurationStore.load()

            let visibleProviders = ConfigurationProviderReadVisibility.visibleProviders()
            let providerCount = visibleProviders.count
            let providerConnected = ConfigurationProviderReadVisibility.connectedCount(visibleProviders)

            let mcpProviders = MCPProviderManager.shared.configuration.providers
            let mcpConnected = MCPProviderManager.shared.providerStates.values
                .filter { $0.isConnected }.count

            let plugins = PluginRepositoryService.shared.plugins
            let installedPlugins = plugins.filter { $0.installedVersion != nil }
            let failedPlugins = installedPlugins.filter { $0.loadError != nil }
            let pluginRepositoryDiagnostic = PluginRepositoryDiagnosticProjection.dictionary(
                PluginRepositoryService.shared.lastRefreshResult
            )

            let schedules = ScheduleManager.shared.schedules
            let enabledSchedules = schedules.filter { $0.isEnabled }

            let watchers = WatcherStore.loadAll()
            let enabledWatchers = watchers.filter { $0.isEnabled }

            let channelConfiguration = AgentChannelConnectionManager.shared.loadConfiguration()
            let enabledChannels = channelConfiguration.connections.filter { $0.enabled }

            let (serverSettings, serverRunning) = ServerController.runtimeSettingsForConfigureTool()
            let memoryConfig = MemoryConfigurationStore.load()

            let sandboxState: String
            switch SandboxManager.State.shared.status {
            case .notProvisioned: sandboxState = "not_provisioned"
            case .stopped: sandboxState = "stopped"
            case .starting: sandboxState = "starting"
            case .running: sandboxState = "running"
            case .error: sandboxState = "error"
            }

            let availableModels = ModelManager.shared.availableModels
            let installedModels = availableModels.filter { $0.isDownloaded }
            let downloadingModels = availableModels.filter { model in
                if case .downloading = ModelManager.shared.effectiveDownloadState(for: model) {
                    return true
                }
                return false
            }

            var suggestions: [String] = []
            if providerCount == 0 && installedModels.isEmpty {
                suggestions.append(
                    "No providers or local models configured — call osaurus_list({scope: 'models', filter: 'recommended'}) for top picks."
                )
            } else {
                if providerCount == 0 {
                    suggestions.append(
                        "No cloud providers configured — search 'add provider' via capabilities_discover."
                    )
                }
                if installedModels.isEmpty {
                    suggestions.append(
                        "No local models installed — search 'download model' via capabilities_discover."
                    )
                }
            }
            if !failedPlugins.isEmpty {
                let names = failedPlugins.prefix(3).map { $0.displayName }.joined(separator: ", ")
                suggestions.append("Plugins failed to load: \(names). Check their manifest / consent state.")
            }
            if !downloadingModels.isEmpty {
                suggestions.append("\(downloadingModels.count) model(s) downloading — poll osaurus_status again.")
            }

            let snapshot: [String: Any] = [
                "active_agent": [
                    "id": activeAgentId.uuidString,
                    "name": activeAgent?.name ?? "Default",
                    "is_built_in": activeAgent?.isBuiltIn ?? true,
                ],
                "default_agent": [
                    "model": defaultConfig.defaultModel ?? "",
                    "system_prompt_set": !defaultConfig.systemPrompt.isEmpty,
                    "autonomous_exec_enabled": defaultConfig.autonomousExec != nil,
                ],
                "models": [
                    "installed_count": installedModels.count,
                    "downloads_in_progress": downloadingModels.count,
                ],
                "providers": [
                    "configured": providerCount,
                    "connected": providerConnected,
                ],
                "mcp": [
                    "configured": mcpProviders.count,
                    "connected": mcpConnected,
                ],
                "plugins": [
                    "installed": installedPlugins.count,
                    "failed": failedPlugins.count,
                    "repository": pluginRepositoryDiagnostic ?? [:],
                ],
                "schedules": [
                    "total": schedules.count,
                    "enabled": enabledSchedules.count,
                ],
                "watchers": [
                    "total": watchers.count,
                    "enabled": enabledWatchers.count,
                ],
                "skills": [
                    "installed": skillCount
                ],
                "knowledge": [
                    "collections": knowledgeTotalCount,
                    "enabled": knowledgeEnabledCount,
                ],
                "channels": [
                    "configured": channelConfiguration.connections.count,
                    "enabled": enabledChannels.count,
                    "bindings": channelConfiguration.bindings.count,
                ],
                "server": [
                    "running": serverRunning,
                    "port": serverSettings.network.port ?? ServerConfiguration.default.port,
                ],
                "memory": [
                    "enabled": memoryConfig.enabled
                ],
                "sandbox": [
                    "provisioned": sandboxState != "not_provisioned",
                    "state": sandboxState,
                ],
                "suggestions": suggestions,
            ]
            return ToolEnvelope.success(tool: name, result: snapshot)
        }
        return envelope
    }
}

// MARK: - osaurus_list

public final class OsaurusListTool: OsaurusTool, @unchecked Sendable {
    public let name = "osaurus_list"
    public let description =
        "List items in a configuration scope. `scope` ∈ "
        + "{agents, models, providers, mcp, plugins, schedules, skills, watchers, "
        + "knowledge, themes, commands, channels, search}. "
        + "Optional `filter` is scope-specific: models: installed|downloading|recommended|all; "
        + "providers/mcp: enabled|disabled|connected|all; plugins: installed|available|failed; "
        + "schedules/watchers/knowledge/channels: enabled|disabled; "
        + "skills/commands: builtin|custom|plugin."
    public let parameters: JSONValue? = .object([
        "type": .string("object"),
        "additionalProperties": .bool(false),
        "properties": .object([
            "scope": .object([
                "type": .string("string"),
                "enum": .array([
                    .string("agents"), .string("models"), .string("providers"),
                    .string("mcp"), .string("plugins"), .string("schedules"),
                    .string("skills"), .string("watchers"), .string("knowledge"),
                    .string("themes"), .string("commands"), .string("channels"),
                    .string("search"),
                ]),
                "description": .string("Configuration scope to list."),
            ]),
            "filter": .object([
                "type": .string("string"),
                "description": .string("Scope-specific. See description."),
            ]),
        ]),
        "required": .array([.string("scope")]),
    ])

    public init() {}

    /// Shared `enabled | disabled | connected` filter for item rows that
    /// carry `enabled` / `connected` booleans (providers, MCP providers).
    /// Unknown filters pass everything through.
    private static func filterByEnabledConnected(
        _ items: [[String: Any]],
        filter: String
    ) -> [[String: Any]] {
        switch filter {
        case "enabled": return items.filter { ($0["enabled"] as? Bool) == true }
        case "disabled": return items.filter { ($0["enabled"] as? Bool) == false }
        case "connected": return items.filter { ($0["connected"] as? Bool) == true }
        default: return items
        }
    }

    /// Shared `builtin | custom | plugin` origin filter for rows that carry
    /// `built_in` / `from_plugin` booleans (skills, slash commands).
    private static func filterByOrigin(
        _ items: [[String: Any]],
        filter: String
    ) -> [[String: Any]] {
        switch filter {
        case "builtin", "built_in":
            return items.filter { ($0["built_in"] as? Bool) == true }
        case "custom":
            return items.filter {
                ($0["built_in"] as? Bool) == false && ($0["from_plugin"] as? Bool) != true
            }
        case "plugin":
            return items.filter { ($0["from_plugin"] as? Bool) == true }
        default: return items
        }
    }

    public func execute(argumentsJSON: String) async throws -> String {
        if let gate = ConfigurationToolBase.defaultAgentGateFailure(tool: name) {
            return gate
        }

        let argsReq = requireArgumentsDictionary(argumentsJSON, tool: name)
        guard case .value(let args) = argsReq else { return argsReq.failureEnvelope ?? "" }
        let scopeReq = requireString(args, "scope", expected: "scope name", tool: name)
        guard case .value(let scope) = scopeReq else { return scopeReq.failureEnvelope ?? "" }
        let filter = (args["filter"] as? String)?.lowercased() ?? ""

        // Skills and knowledge collections load from disk off the main
        // actor (their stores are async / main-thread-hostile), so those
        // scopes resolve before the MainActor hop below.
        switch scope {
        case "skills":
            let skills = await SkillStore.loadAll()
            let items = skills.map { skill -> [String: Any] in
                return [
                    "id": skill.id.uuidString,
                    "name": skill.name,
                    "description": skill.description,
                    "category": skill.category ?? "",
                    "built_in": skill.isBuiltIn,
                    "from_plugin": skill.isFromPlugin,
                ]
            }
            return ToolEnvelope.success(
                tool: name,
                result: [
                    "scope": "skills", "filter": filter,
                    "items": Self.filterByOrigin(items, filter: filter),
                ]
            )
        case "knowledge":
            let collections = await KnowledgeCollectionStore.loadAllAsync()
            let items = collections.map { c -> [String: Any] in
                return [
                    "id": c.id.uuidString,
                    "name": c.name,
                    "summary": c.summary,
                    "folder_path": c.folderPath,
                    "enabled": c.isEnabled,
                    "git_synced": c.gitRemoteURL != nil,
                ]
            }
            return ToolEnvelope.success(
                tool: name,
                result: [
                    "scope": "knowledge", "filter": filter,
                    "items": Self.filterByEnabledConnected(items, filter: filter),
                ]
            )
        default:
            break
        }

        let envelope: String = await MainActor.run {
            let payload: [String: Any]
            switch scope {
            case "agents":
                let agents = AgentManager.shared.agents.map { agent -> [String: Any] in
                    return [
                        "id": agent.id.uuidString,
                        "name": agent.name,
                        "is_built_in": agent.isBuiltIn,
                    ]
                }
                payload = ["scope": "agents", "items": agents]
            case "models":
                let all = ModelManager.shared.availableModels
                let filtered: [MLXModel]
                switch filter {
                case "installed", "":
                    filtered = all.filter { $0.isDownloaded }
                case "downloading":
                    filtered = all.filter {
                        if case .downloading = ModelManager.shared.effectiveDownloadState(for: $0) {
                            return true
                        }
                        return false
                    }
                case "all":
                    filtered = all
                case "recommended":
                    filtered = Array(all.prefix(10))
                default:
                    filtered = all.filter { $0.isDownloaded }
                }
                let items = filtered.map { model -> [String: Any] in
                    var dict: [String: Any] = [
                        "id": model.id,
                        "name": model.name,
                    ]
                    if let bytes = model.totalSizeEstimateBytes { dict["size_bytes"] = bytes }
                    return dict
                }
                payload = ["scope": "models", "filter": filter.isEmpty ? "installed" : filter, "items": items]
            case "providers":
                let providers = ConfigurationProviderReadVisibility.visibleProviders()
                let items = providers.map { p -> [String: Any] in
                    let state = RemoteProviderManager.shared.providerStates[p.id]
                    return [
                        "id": p.id.uuidString,
                        "name": p.name,
                        "provider_type": p.providerType.rawValue,
                        "enabled": p.enabled,
                        "connected": state?.isConnected ?? false,
                        "has_api_key": p.hasAPIKey,
                        "has_oauth": p.hasOAuthTokens,
                    ]
                }
                payload = [
                    "scope": "providers", "filter": filter,
                    "items": Self.filterByEnabledConnected(items, filter: filter),
                ]
            case "mcp", "mcp_providers":
                let providers = MCPProviderManager.shared.configuration.providers
                let items = providers.map { p -> [String: Any] in
                    let state = MCPProviderManager.shared.providerStates[p.id]
                    return [
                        "id": p.id.uuidString,
                        "name": p.name,
                        "url": p.url,
                        "auth": p.authType.rawValue,
                        "enabled": p.enabled,
                        "connected": state?.isConnected ?? false,
                        "has_token": p.hasToken,
                        "has_oauth": p.hasOAuthTokens,
                    ]
                }
                payload = [
                    "scope": "mcp", "filter": filter,
                    "items": Self.filterByEnabledConnected(items, filter: filter),
                ]
            case "plugins":
                let plugins = PluginRepositoryService.shared.plugins
                let items = plugins.map { state -> [String: Any] in
                    return [
                        "plugin_id": state.pluginId,
                        "name": state.displayName,
                        "installed": state.installedVersion != nil,
                        "has_load_error": state.loadError != nil,
                    ]
                }
                let filtered: [[String: Any]]
                switch filter {
                case "installed":
                    filtered = items.filter { ($0["installed"] as? Bool) == true }
                case "available":
                    filtered = items.filter { ($0["installed"] as? Bool) == false }
                case "failed":
                    filtered = items.filter { ($0["has_load_error"] as? Bool) == true }
                default:
                    filtered = items
                }
                payload = [
                    "scope": "plugins",
                    "filter": filter,
                    "repository": PluginRepositoryDiagnosticProjection.dictionary(
                        PluginRepositoryService.shared.lastRefreshResult
                    ) ?? [:],
                    "items": filtered,
                ]
            case "schedules":
                let schedules = ScheduleManager.shared.schedules.map { s -> [String: Any] in
                    return [
                        "id": s.id.uuidString,
                        "name": s.name,
                        "enabled": s.isEnabled,
                        "frequency": s.frequency.displayDescription,
                    ]
                }
                let filtered: [[String: Any]]
                switch filter {
                case "enabled": filtered = schedules.filter { ($0["enabled"] as? Bool) == true }
                case "disabled": filtered = schedules.filter { ($0["enabled"] as? Bool) == false }
                default: filtered = schedules
                }
                payload = ["scope": "schedules", "filter": filter, "items": filtered]
            case "watchers":
                let watchers = WatcherStore.loadAll().map { w -> [String: Any] in
                    return [
                        "id": w.id.uuidString,
                        "name": w.name,
                        "enabled": w.isEnabled,
                        "watch_path": w.watchPath ?? "",
                        "agent_id": w.agentId?.uuidString ?? "",
                        "recursive": w.recursive,
                    ]
                }
                payload = [
                    "scope": "watchers", "filter": filter,
                    "items": Self.filterByEnabledConnected(watchers, filter: filter),
                ]
            case "themes":
                let activeId = ThemeConfigurationStore.loadActiveThemeId()
                let themes = ThemeConfigurationStore.listThemes().map { theme -> [String: Any] in
                    return [
                        "id": theme.metadata.id.uuidString,
                        "name": theme.metadata.name,
                        "author": theme.metadata.author,
                        "built_in": theme.isBuiltIn,
                        "active": theme.metadata.id == activeId,
                    ]
                }
                payload = ["scope": "themes", "filter": filter, "items": themes]
            case "commands":
                // Built-ins live in code, custom commands on disk — the
                // popup shows both, so the read scope must too.
                let commands = (SlashCommand.builtIns + SlashCommandStore.loadAll())
                    .map { cmd -> [String: Any] in
                        return [
                            "id": cmd.id.uuidString,
                            "name": cmd.name,
                            "description": cmd.description,
                            "kind": cmd.kind.rawValue,
                            "built_in": cmd.isBuiltIn,
                            "from_plugin": cmd.pluginId != nil,
                        ]
                    }
                payload = [
                    "scope": "commands", "filter": filter,
                    "items": Self.filterByOrigin(commands, filter: filter),
                ]
            case "channels":
                let configuration = AgentChannelConnectionManager.shared.loadConfiguration()
                let bindingCounts = configuration.bindings.reduce(into: [String: Int]()) {
                    counts, binding in
                    counts[binding.connectionId, default: 0] += 1
                }
                let connections = configuration.connections.map { c -> [String: Any] in
                    return [
                        "id": c.id,
                        "name": c.name,
                        "kind": c.kind.rawValue,
                        "enabled": c.enabled,
                        "write_enabled": c.writeEnabled,
                        "binding_count": bindingCounts[c.id] ?? 0,
                    ]
                }
                payload = [
                    "scope": "channels", "filter": filter,
                    "items": Self.filterByEnabledConnected(connections, filter: filter),
                ]
            case "search":
                let manager = SearchProviderManager.shared
                let configured = manager.configuredProviderIds
                let providers = manager.rankedProviders.enumerated().map { index, entry -> [String: Any] in
                    let (provider, def) = entry
                    var row: [String: Any] = [
                        "id": def.id,
                        "name": def.name,
                        "rank": index + 1,
                        "enabled": provider.enabled,
                        "free": def.isKeyless,
                    ]
                    if !def.isKeyless {
                        row["configured"] = configured.contains(def.id)
                    }
                    return row
                }
                payload = [
                    "scope": "search", "filter": filter,
                    "items": Self.filterByEnabledConnected(providers, filter: filter),
                    "note": "Rank 1 is tried first; lower ranks are fallbacks. Use osaurus_search to modify.",
                ]
            default:
                return ToolEnvelope.failure(
                    kind: .invalidArgs,
                    message:
                        "Unknown scope `\(scope)`. Valid: agents, models, providers, mcp, plugins, "
                        + "schedules, skills, watchers, knowledge, themes, commands, channels, search.",
                    field: "scope",
                    tool: name
                )
            }
            return ToolEnvelope.success(tool: name, result: payload)
        }
        return envelope
    }
}

// MARK: - osaurus_help

public final class OsaurusHelpTool: OsaurusTool, @unchecked Sendable {
    public let name = "osaurus_help"
    public let description =
        "Bundled Osaurus user guide — answers questions about what Osaurus is and how its features "
        + "work (models, providers, agents, skills, plugins, MCP, schedules, memory, server/API, "
        + "voice, themes, channels, automation). "
        + "`action`: topics (index of topic ids with summaries), read (needs `topic` id; returns the "
        + "full topic text). Answer from the topic text — for the user's CURRENT configuration use "
        + "osaurus_status / osaurus_list instead."
    public let parameters: JSONValue? = .object([
        "type": .string("object"),
        "additionalProperties": .bool(false),
        "properties": .object([
            "action": .object([
                "type": .string("string"),
                "enum": .array([.string("topics"), .string("read")]),
                "description": .string("Operation: list all topics, or read one topic."),
            ]),
            "topic": .object([
                "type": .string("string"),
                "description": .string(
                    "Topic id from the `topics` index (e.g. getting-started, local-models). Required for read."
                ),
            ]),
        ]),
        "required": .array([.string("action")]),
    ])

    public init() {}

    public func execute(argumentsJSON: String) async throws -> String {
        if let gate = ConfigurationToolBase.defaultAgentGateFailure(tool: name) {
            return gate
        }
        let argsReq = requireArgumentsDictionary(argumentsJSON, tool: name)
        guard case .value(let args) = argsReq else { return argsReq.failureEnvelope ?? "" }
        let actionReq = requireAction(args, allowed: ["topics", "read"])
        guard case .value(let action) = actionReq else { return actionReq.failureEnvelope ?? "" }

        switch action {
        case "topics":
            let items = OsaurusGuide.topics.map { topic -> [String: Any] in
                ["id": topic.id, "title": topic.title, "summary": topic.summary]
            }
            return ToolEnvelope.success(
                tool: name,
                result: [
                    "topics": items,
                    "note": "Call osaurus_help({action: 'read', topic: '<id>'}) for the full text.",
                ]
            )
        case "read":
            let topicReq = requireString(args, "topic", expected: "topic id", tool: name)
            guard case .value(let topicId) = topicReq else { return topicReq.failureEnvelope ?? "" }
            guard let topic = OsaurusGuide.topic(id: topicId) else {
                let known = OsaurusGuide.topics.map { $0.id }.joined(separator: ", ")
                return ToolEnvelope.failure(
                    kind: .invalidArgs,
                    message: "No guide topic `\(topicId)`. Known topics: \(known).",
                    field: "topic",
                    tool: name
                )
            }
            return ToolEnvelope.success(
                tool: name,
                result: [
                    "id": topic.id,
                    "title": topic.title,
                    "content": topic.body,
                ]
            )
        default:
            return actionReq.failureEnvelope ?? ""
        }
    }
}

// MARK: - osaurus_describe

public final class OsaurusDescribeTool: OsaurusTool, @unchecked Sendable {
    public let name = "osaurus_describe"
    public let description =
        "Full detail for one item in a configuration scope. Same scopes as osaurus_list. "
        + "For providers, includes runtime `connected` / `last_error` / `discovered_models`. "
        + "For agents, includes effective resolved settings. "
        + "Skills, knowledge collections, and commands also match by name (case-insensitive)."
    public let parameters: JSONValue? = .object([
        "type": .string("object"),
        "additionalProperties": .bool(false),
        "properties": .object([
            "scope": .object([
                "type": .string("string"),
                "enum": .array([
                    .string("agents"), .string("models"), .string("providers"),
                    .string("mcp"), .string("plugins"), .string("schedules"),
                    .string("skills"), .string("watchers"), .string("knowledge"),
                    .string("themes"), .string("commands"), .string("channels"),
                    .string("search"),
                ]),
                "description": .string("Configuration scope of the item."),
            ]),
            "id": .object(["type": .string("string")]),
        ]),
        "required": .array([.string("scope"), .string("id")]),
    ])

    public init() {}

    public func execute(argumentsJSON: String) async throws -> String {
        if let gate = ConfigurationToolBase.defaultAgentGateFailure(tool: name) {
            return gate
        }
        let argsReq = requireArgumentsDictionary(argumentsJSON, tool: name)
        guard case .value(let args) = argsReq else { return argsReq.failureEnvelope ?? "" }
        let scopeReq = requireString(args, "scope", expected: "scope name", tool: name)
        guard case .value(let scope) = scopeReq else { return scopeReq.failureEnvelope ?? "" }
        let idReq = requireString(args, "id", expected: "identifier", tool: name)
        guard case .value(let idStr) = idReq else { return idReq.failureEnvelope ?? "" }

        // Skills and knowledge collections load from disk off the main
        // actor; resolve those scopes before the MainActor hop below.
        switch scope {
        case "skills":
            let skills = await SkillStore.loadAll()
            let uuid = UUID(uuidString: idStr)
            guard
                let skill = skills.first(where: {
                    $0.id == uuid || $0.name.caseInsensitiveCompare(idStr) == .orderedSame
                })
            else {
                return Self.notFoundFailure(scope: scope, id: idStr, tool: name)
            }
            var result: [String: Any] = [
                "scope": "skills",
                "id": skill.id.uuidString,
                "name": skill.name,
                "description": skill.description,
                "version": skill.version,
                "category": skill.category ?? "",
                "keywords": skill.keywords,
                "built_in": skill.isBuiltIn,
                "from_plugin": skill.isFromPlugin,
                "reference_file_count": skill.references.count,
                "asset_file_count": skill.assets.count,
            ]
            if let pluginId = skill.pluginId { result["plugin_id"] = pluginId }
            return ToolEnvelope.success(tool: name, result: result)
        case "knowledge":
            let collections = await KnowledgeCollectionStore.loadAllAsync()
            let uuid = UUID(uuidString: idStr)
            guard
                let collection = collections.first(where: {
                    $0.id == uuid || $0.name.caseInsensitiveCompare(idStr) == .orderedSame
                })
            else {
                return Self.notFoundFailure(scope: scope, id: idStr, tool: name)
            }
            return ToolEnvelope.success(
                tool: name,
                result: [
                    "scope": "knowledge",
                    "id": collection.id.uuidString,
                    "name": collection.name,
                    "summary": collection.summary,
                    "folder_path": collection.folderPath,
                    "enabled": collection.isEnabled,
                    "git_remote_url": collection.gitRemoteURL ?? "",
                ]
            )
        default:
            break
        }

        let envelope: String = await MainActor.run {
            let payload: [String: Any]?
            switch scope {
            case "agents":
                if let uuid = UUID(uuidString: idStr),
                    let agent = AgentManager.shared.agent(for: uuid)
                {
                    payload = [
                        "id": agent.id.uuidString,
                        "name": agent.name,
                        "description": agent.description,
                        "system_prompt": agent.systemPrompt,
                        "default_model": agent.defaultModel ?? "",
                        "temperature": agent.temperature ?? 0,
                        "max_tokens": agent.maxTokens ?? 0,
                        "is_built_in": agent.isBuiltIn,
                        "capabilities": AgentConfigurationDomain.capabilitiesPayload(for: agent),
                    ]
                } else {
                    payload = nil
                }
            case "models":
                if let model = ModelManager.shared.availableModels.first(where: { $0.id == idStr })
                    ?? ModelManager.shared.suggestedModels.first(where: { $0.id == idStr })
                {
                    var dict: [String: Any] = [
                        "id": model.id,
                        "name": model.name,
                        "description": model.description,
                        "installed": model.isDownloaded,
                    ]
                    if let bytes = model.totalSizeEstimateBytes { dict["size_bytes"] = bytes }
                    payload = dict
                } else {
                    payload = nil
                }
            case "providers":
                if let uuid = UUID(uuidString: idStr),
                    let p = ConfigurationProviderReadVisibility.visibleProviders()
                        .first(where: { $0.id == uuid })
                {
                    let state = RemoteProviderManager.shared.providerStates[uuid]
                    payload = [
                        "id": p.id.uuidString,
                        "name": p.name,
                        "provider_type": p.providerType.rawValue,
                        "host": p.host,
                        "enabled": p.enabled,
                        "auto_connect": p.autoConnect,
                        "connected": state?.isConnected ?? false,
                        "has_api_key": p.hasAPIKey,
                        "has_oauth": p.hasOAuthTokens,
                        "last_error": state?.lastError ?? "",
                        "discovered_models": state?.discoveredModels ?? [],
                    ]
                } else {
                    payload = nil
                }
            case "mcp", "mcp_providers":
                if let uuid = UUID(uuidString: idStr),
                    let p = MCPProviderManager.shared.configuration.provider(id: uuid)
                {
                    let state = MCPProviderManager.shared.providerStates[uuid]
                    payload = [
                        "id": p.id.uuidString,
                        "name": p.name,
                        "url": p.url,
                        "auth": p.authType.rawValue,
                        "transport": p.transport.rawValue,
                        "enabled": p.enabled,
                        "auto_connect": p.autoConnect,
                        "connected": state?.isConnected ?? false,
                        "has_token": p.hasToken,
                        "has_oauth": p.hasOAuthTokens,
                        "requires_auth": state?.requiresAuth ?? false,
                        "last_error": state?.lastError ?? "",
                        "discovered_tools": state?.discoveredToolNames ?? [],
                    ]
                } else {
                    payload = nil
                }
            case "plugins":
                if let plugin = PluginRepositoryService.shared.plugins
                    .first(where: { $0.pluginId == idStr })
                {
                    payload = [
                        "plugin_id": plugin.pluginId,
                        "name": plugin.displayName,
                        "installed": plugin.installedVersion != nil,
                        "installed_version": plugin.installedVersion?.description ?? "",
                        "latest_version": plugin.latestVersion?.description ?? "",
                        "load_error": plugin.loadError ?? "",
                    ]
                } else {
                    payload = nil
                }
            case "schedules":
                if let uuid = UUID(uuidString: idStr),
                    let s = ScheduleManager.shared.schedule(for: uuid)
                {
                    payload = [
                        "id": s.id.uuidString,
                        "name": s.name,
                        "instructions": s.instructions,
                        "agent_id": s.agentId?.uuidString ?? "",
                        "enabled": s.isEnabled,
                        "frequency": s.frequency.displayDescription,
                    ]
                } else {
                    payload = nil
                }
            case "watchers":
                if let uuid = UUID(uuidString: idStr),
                    let w = WatcherStore.loadAll().first(where: { $0.id == uuid })
                {
                    var dict: [String: Any] = [
                        "id": w.id.uuidString,
                        "name": w.name,
                        "instructions": w.instructions,
                        "watch_path": w.watchPath ?? "",
                        "agent_id": w.agentId?.uuidString ?? "",
                        "enabled": w.isEnabled,
                        "recursive": w.recursive,
                        "responsiveness": w.responsiveness.rawValue,
                    ]
                    if let last = w.lastTriggeredAt {
                        dict["last_triggered_at"] = ISO8601DateFormatter().string(from: last)
                    }
                    payload = dict
                } else {
                    payload = nil
                }
            case "themes":
                let uuid = UUID(uuidString: idStr)
                if let theme = ThemeConfigurationStore.listThemes().first(where: {
                    $0.metadata.id == uuid
                        || $0.metadata.name.caseInsensitiveCompare(idStr) == .orderedSame
                }) {
                    payload = [
                        "id": theme.metadata.id.uuidString,
                        "name": theme.metadata.name,
                        "author": theme.metadata.author,
                        "version": theme.metadata.version,
                        "built_in": theme.isBuiltIn,
                        "dark": theme.isDark,
                        "active": theme.metadata.id == ThemeConfigurationStore.loadActiveThemeId(),
                    ]
                } else {
                    payload = nil
                }
            case "commands":
                let uuid = UUID(uuidString: idStr)
                let allCommands = SlashCommand.builtIns + SlashCommandStore.loadAll()
                if let cmd = allCommands.first(where: {
                    $0.id == uuid || $0.name.caseInsensitiveCompare(idStr) == .orderedSame
                }) {
                    var dict: [String: Any] = [
                        "id": cmd.id.uuidString,
                        "name": cmd.name,
                        "description": cmd.description,
                        "kind": cmd.kind.rawValue,
                        "built_in": cmd.isBuiltIn,
                        "from_plugin": cmd.pluginId != nil,
                    ]
                    if let template = cmd.template { dict["template"] = template }
                    payload = dict
                } else {
                    payload = nil
                }
            case "channels":
                let configuration = AgentChannelConnectionManager.shared.loadConfiguration()
                if let c = configuration.connections.first(where: { $0.id == idStr }) {
                    let bindings = configuration.bindings
                        .filter { $0.connectionId == c.id }
                        .map { binding -> [String: Any] in
                            return [
                                "id": binding.id,
                                "agent_id": binding.agentId.uuidString,
                                "enabled": binding.enabled,
                            ]
                        }
                    payload = [
                        "id": c.id,
                        "name": c.name,
                        "kind": c.kind.rawValue,
                        "enabled": c.enabled,
                        "write_enabled": c.writeEnabled,
                        "supported_actions": c.supportedActions.map { $0.rawValue },
                        "space_allowlist": c.spaceAllowlist,
                        "read_room_allowlist": c.readRoomAllowlist,
                        "write_room_allowlist": c.writeRoomAllowlist,
                        "has_secrets": !c.secrets.isEmpty,
                        "bindings": bindings,
                    ]
                } else {
                    payload = nil
                }
            case "search":
                let manager = SearchProviderManager.shared
                if let entry = manager.rankedProviders.enumerated().first(where: {
                    $0.element.definition.id == idStr
                }) {
                    let (provider, def) = entry.element
                    var dict: [String: Any] = [
                        "id": def.id,
                        "name": def.name,
                        "rank": entry.offset + 1,
                        "enabled": provider.enabled,
                        "free": def.isKeyless,
                        "categories": def.supportedCategories,
                    ]
                    if !def.isKeyless {
                        dict["configured"] = manager.configuredProviderIds.contains(def.id)
                    }
                    payload = dict
                } else {
                    payload = nil
                }
            default:
                payload = nil
            }
            guard let payload else {
                return Self.notFoundFailure(scope: scope, id: idStr, tool: name)
            }
            var result = payload
            result["scope"] = scope
            return ToolEnvelope.success(tool: name, result: result)
        }
        return envelope
    }

    private static func notFoundFailure(scope: String, id: String, tool: String) -> String {
        ToolEnvelope.failure(
            kind: .invalidArgs,
            message: "No `\(scope)` found with id `\(id)`.",
            tool: tool
        )
    }
}
