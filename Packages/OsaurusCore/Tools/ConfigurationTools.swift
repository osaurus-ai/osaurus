//
//  ConfigurationTools.swift
//  osaurus
//
//  The three "always loaded" read tools the default agent uses to
//  inspect Osaurus's current configuration:
//
//   - osaurus_status   — one-shot snapshot + suggestions
//   - osaurus_list     — list items in a scope
//   - osaurus_describe — full detail for one item
//
//  These tools intentionally don't emit secrets. Provider rows expose
//  "has API key" booleans rather than the key itself, and `hasOAuth`
//  is exposed as a connection-status hint.
//
//  Each tool runs the same `ConfigurationToolBase.defaultAgentGateFailure`
//  check the write tools use, so reading is also default-agent-only.
//

import Foundation

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

// MARK: - osaurus_status

public final class OsaurusStatusTool: OsaurusTool, @unchecked Sendable {
    public let name = "osaurus_status"
    public let description =
        "One-shot snapshot of Osaurus configuration: default agent, hardware, models, providers, "
        + "plugins, schedules. Returns `suggestions` derived from the snapshot — call this first when "
        + "the user says 'help me set up Osaurus' or asks what's configured."
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

            let schedules = ScheduleManager.shared.schedules
            let enabledSchedules = schedules.filter { $0.isEnabled }

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
                ],
                "schedules": [
                    "total": schedules.count,
                    "enabled": enabledSchedules.count,
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
        + "{agents, models, providers, mcp, plugins, schedules}. "
        + "Optional `filter` is scope-specific: models: installed|downloading|recommended|all; "
        + "providers/mcp: enabled|disabled|connected|all; plugins: installed|available|failed; "
        + "schedules: enabled|disabled."
    public let parameters: JSONValue? = .object([
        "type": .string("object"),
        "additionalProperties": .bool(false),
        "properties": .object([
            "scope": .object([
                "type": .string("string"),
                "enum": .array([
                    .string("agents"), .string("models"), .string("providers"),
                    .string("mcp"), .string("plugins"), .string("schedules"),
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

    public func execute(argumentsJSON: String) async throws -> String {
        if let gate = ConfigurationToolBase.defaultAgentGateFailure(tool: name) {
            return gate
        }

        let argsReq = requireArgumentsDictionary(argumentsJSON, tool: name)
        guard case .value(let args) = argsReq else { return argsReq.failureEnvelope ?? "" }
        let scopeReq = requireString(args, "scope", expected: "scope name", tool: name)
        guard case .value(let scope) = scopeReq else { return scopeReq.failureEnvelope ?? "" }
        let filter = (args["filter"] as? String)?.lowercased() ?? ""

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
                payload = ["scope": "plugins", "filter": filter, "items": filtered]
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
            default:
                return ToolEnvelope.failure(
                    kind: .invalidArgs,
                    message: "Unknown scope `\(scope)`. Valid: agents, models, providers, mcp, plugins, schedules.",
                    field: "scope",
                    tool: name
                )
            }
            return ToolEnvelope.success(tool: name, result: payload)
        }
        return envelope
    }
}

// MARK: - osaurus_describe

public final class OsaurusDescribeTool: OsaurusTool, @unchecked Sendable {
    public let name = "osaurus_describe"
    public let description =
        "Full detail for one item in a configuration scope. Same scopes as osaurus_list. "
        + "For providers, includes runtime `connected` / `last_error` / `discovered_models`. "
        + "For agents, includes effective resolved settings."
    public let parameters: JSONValue? = .object([
        "type": .string("object"),
        "additionalProperties": .bool(false),
        "properties": .object([
            "scope": .object([
                "type": .string("string"),
                "enum": .array([
                    .string("agents"), .string("models"), .string("providers"),
                    .string("mcp"), .string("plugins"), .string("schedules"),
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
            default:
                payload = nil
            }
            guard let payload else {
                return ToolEnvelope.failure(
                    kind: .invalidArgs,
                    message: "No `\(scope)` found with id `\(idStr)`.",
                    tool: name
                )
            }
            var result = payload
            result["scope"] = scope
            return ToolEnvelope.success(tool: name, result: result)
        }
        return envelope
    }
}
