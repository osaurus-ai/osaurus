//
//  ConfigurationTools.swift
//  osaurus
//
//  The two "always loaded" read tools the default agent uses to
//  inspect Osaurus's current configuration and explain the app:
//
//   - osaurus_inspect — action: status (snapshot + suggestions),
//     list (rows in a scope), describe (full detail for one item)
//   - osaurus_help    — bundled user-guide topics about Osaurus itself
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
/// Agent-facing capability payload for describe reads. Lived on the old
/// `AgentConfigurationDomain` before the per-domain write tools were replaced
/// by the declarative `osaurus_config` surface.
enum AgentCapabilitiesPayload {
    static func payload(for agent: Agent) -> [String: Any] {
        [
            "tools_enabled": agent.toolsEnabled,
            "memory_enabled": agent.memoryEnabled,
            "search_memory_enabled": agent.settings.searchMemoryEnabled,
            "web_search_enabled": agent.settings.webSearchEnabled,
            "knowledge_enabled": agent.settings.knowledgeEnabled,
            "knowledge_collection_ids": agent.settings.knowledgeCollectionIds
                .map { $0.uuidString },
            "db_enabled": agent.settings.dbEnabled,
            "self_scheduling_enabled": agent.settings.selfSchedulingEnabled,
            "computer_use_enabled": agent.settings.computerUseEnabled,
            "browser_use_enabled": agent.settings.browserUseEnabled,
            "speak_enabled": agent.settings.speakEnabled,
            "render_chart_enabled": agent.settings.renderChartEnabled,
            "theme_id": agent.themeId?.uuidString ?? "",
        ]
    }
}

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

/// Appended to every read-tool success envelope. Small models read-loop on
/// `osaurus_inspect`/`osaurus_help` and never reach `osaurus_config` (whose
/// own responses carry next-step hints) — so the bridge to the write tool
/// must live on the READ results they are actually looking at.
///
/// Scoped reads (list/describe) additionally embed the declarative YAML
/// shape for the section that writes that scope (`yaml_shape`, rendered
/// from `ConfigManifest` so it cannot drift). That collapses the
/// inspect → schema → plan → apply choreography to inspect → apply: the
/// model no longer needs a separate `schema` call to learn the document
/// shape for the thing it just read.
enum ConfigurationReadNextStep {
    /// THE write contract, stated once (Gap 0.5 consolidation). The same
    /// rules previously lived in `hint`, `hintWithShape`, the shape header,
    /// and the prompt paragraphs in slightly different words — bulk that
    /// itself degraded small-model runs. Every read hint and the prompt
    /// builder reference this constant so the rules cannot drift apart.
    static let writeContract =
        "To CHANGE configuration, compose a minimal YAML with only the keys to change and "
        + "call osaurus_config {action: 'apply', yaml: ...}. Apply is the only action that "
        + "changes anything. Never end your turn asking whether to apply — CALL apply; the "
        + "native one-tap approval card is the user's confirmation. "
        + "To DELETE entries, apply the section listing only the entries to KEEP with the "
        + "tool argument prune: true — prune goes beside yaml, never inside the document. "
        + "To set or rotate a provider's API key, apply set_api_key: true (never the key "
        + "value); only when the user names where the secret lives, reference it with "
        + "api_key_ref / token_ref: env:VAR_NAME or keychain:SERVICE/ACCOUNT — never "
        + "invent a ref."

    /// Read-envelope hint. `hasShape` distinguishes scoped reads (which
    /// embed `yaml_shape`, so no schema call is needed) from shapeless ones.
    static func hint(hasShape: Bool) -> String {
        let lead =
            hasShape
            ? "This result is read-only. Use `yaml_shape` below as the document shape — "
                + "no schema call needed. "
            : "This result is read-only. Get the document shape with osaurus_config "
                + "{action: 'schema', sections: [...]} if unsure. "
        return lead + writeContract
            + " If the user only asked a question, answer from this result in plain text."
    }

    /// Status is the one read with no single scope, and it is where models
    /// land first for app-wide settings asks. Observed dead ends get
    /// explicit routes: settings sections are NOT inspect scopes (they are
    /// read via export), server/chat/app settings are Settings-UI-only, and
    /// "what is Osaurus / how does X work" questions belong to
    /// `osaurus_help`, not to a snapshot recital.
    static let statusHint =
        hint(hasShape: false)
        + " Settings sections (memory, default_agent, tools, delegation) "
        + "are document sections: read one with osaurus_inspect {action: 'describe', "
        + "scope: '<section>'} (or osaurus_config {action: 'export', sections: [...]}), "
        + "and change it with osaurus_config {action: 'apply', yaml: ...}. "
        + "Server runtime, chat behavior, and app settings are managed in the Settings UI, "
        + "not with these tools. "
        + "For questions about what Osaurus is or how a feature works, read the matching "
        + "osaurus_help topic instead of answering from this snapshot."

    /// Short semantics header prepended to every embedded `yaml_shape`.
    /// The shape short-circuit means small models may never call schema —
    /// so the rules the failing runs actually needed ride with the shape.
    /// Write mechanics live in `writeContract` (carried by the hint); this
    /// header keeps only shape-reading semantics and the delete-honesty
    /// guard. The secrets line rides only on scopes carrying credentials.
    static let shapeSemanticsHeader = """
        # Entities match by name; keys absent from the document stay unchanged.
        # ADDING an entry that is not yet listed is the normal way to create \
        or install it. DELETING is different: if asked to remove an entry \
        that is not in the current list, say so instead of applying.
        """

    static let secretScopeSemantics = """
        # Secrets never go in YAML, and reads/exports NEVER show whether a key \
        is stored — never conclude from a read that a key is missing or empty. \
        set_api_key: true opens the native key sheet during apply; api_key_ref \
        / token_ref accept env:VAR_NAME or keychain:SERVICE/ACCOUNT (the secret \
        is read during apply — you never see it). Never ask the user to paste \
        a key in chat.
        """

    /// Scopes whose entries carry credentials and therefore get the
    /// secret-handling semantics in their shape header.
    static let secretScopes: Set<String> = ["providers", "mcp", "mcp_providers", "channels"]

    /// One-line counters to observed false beliefs that survive even with
    /// the shape in view: models that read the roster and still narrate
    /// "downloads happen in the UI" or "openrouter isn't a real provider".
    static let scopeCapabilityLines: [String: String] = [
        "models": """
            # YOU can install models from right here: apply with `models:` listing \
            the installed repo ids PLUS the new one — that STARTS the download. \
            Never redirect the user to the UI or another assistant for this. \
            Listing a model here only INSTALLS it — to make an agent USE a model, \
            set default_agent.model (the Default agent) or agents[].model (a custom \
            agent). `foundation` (the built-in Apple Foundation on-device model) \
            never appears in this list but is ALWAYS a valid value for those model \
            keys — never refuse it as "not installed".
            """,
        "providers": """
            # EVERY id in the `provider` list above is a directly supported \
            provider (openrouter included) — connect one by applying a providers \
            entry with that id. Never claim a listed provider is unsupported.
            """,
        "plugins": """
            # The list above shows INSTALLED plugins only — it is NOT the \
            registry. YOU install a registry plugin from right here: apply with \
            `plugins:` listing the installed ids PLUS the new id. The registry is \
            checked at apply (an unknown id fails with a clear error), so apply \
            directly instead of trying to pre-verify. Never redirect the user to \
            the UI or another assistant for this.
            """,
    ]

    static func semanticsHeader(forScope scope: String) -> String {
        var header = shapeSemanticsHeader
        if secretScopes.contains(scope) {
            header += "\n" + secretScopeSemantics
        }
        if let capability = scopeCapabilityLines[scope] {
            header += "\n" + capability
        }
        return header
    }

    /// Declarative sections whose YAML shape a read scope embeds. Scopes
    /// without a declarative writer (skills, themes) map to nothing and
    /// keep the plain hint.
    static func shapeSections(forScope scope: String) -> Set<ConfigSectionID>? {
        switch scope {
        case "agents": return [.agents, .activeAgent]
        case "models": return [.models]
        case "providers": return [.providers]
        case "mcp", "mcp_providers": return [.mcpServers]
        case "plugins": return [.plugins]
        case "schedules": return [.schedules]
        case "watchers": return [.watchers]
        case "knowledge": return [.knowledgeCollections]
        case "commands": return [.commands]
        case "channels": return [.channels]
        case "search": return [.searchProviders]
        default: return nil
        }
    }

    static func success(tool: String, result: [String: Any], scope: String? = nil) -> String {
        var result = result
        if let scope, let sections = shapeSections(forScope: scope) {
            result["yaml_shape"] =
                semanticsHeader(forScope: scope) + "\n"
                + ConfigManifest.renderedSchemaSections(only: sections)
            result["next_step"] = hint(hasShape: true)
        } else {
            result["next_step"] = hint(hasShape: false)
        }
        return ToolEnvelope.success(tool: tool, result: result)
    }

    /// Variant for `osaurus_inspect` status.
    static func statusSuccess(tool: String, result: [String: Any]) -> String {
        var result = result
        result["next_step"] = statusHint
        return ToolEnvelope.success(tool: tool, result: result)
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

// MARK: - osaurus_inspect

/// Single read surface for Osaurus configuration, replacing the former
/// `osaurus_status` / `osaurus_list` / `osaurus_describe` triple. One name,
/// one scope enum, three depths: `status` (aggregate snapshot with
/// suggestions), `list` (rows in a scope), `describe` (one item in full).
public final class OsaurusInspectTool: OsaurusTool, @unchecked Sendable {
    public let name = "osaurus_inspect"
    public let description =
        "Read Osaurus configuration. `action`: status (one-shot snapshot of everything — default "
        + "agent, server, models, providers, plugins, schedules, watchers, skills, knowledge, "
        + "channels, memory, sandbox — plus `suggestions`; call it first when the user asks "
        + "what's configured), list (rows in one `scope`), describe (full detail for one item; "
        + "needs `scope` + `id`; providers/mcp include runtime connected/last_error; skills, "
        + "knowledge, commands, themes also match by name). "
        + "`scope` ∈ {agents, models, providers, mcp, plugins, schedules, skills, watchers, "
        + "knowledge, themes, commands, channels, search}. "
        + "Optional `filter` (list only): models: installed|downloading|recommended|all; "
        + "providers/mcp: enabled|disabled|connected|all; plugins: installed|available|failed; "
        + "schedules/watchers/knowledge/channels: enabled|disabled; "
        + "skills/commands: builtin|custom|plugin."
    public let parameters: JSONValue? = .object([
        "type": .string("object"),
        "additionalProperties": .bool(false),
        "properties": .object([
            "action": .object([
                "type": .string("string"),
                "enum": .array([.string("status"), .string("list"), .string("describe")]),
                "description": .string("Read depth: whole-app snapshot, scope rows, or one item."),
            ]),
            // The enum is load-bearing for small models: prompt compaction
            // strips description prose but KEEPS enums, so this list is the
            // only scope roster a compact-schema model ever sees (removing
            // it regressed scope-less/junk-arg calls immediately). It also
            // includes the settings DOCUMENT SECTIONS (`memory`, `tools`, …)
            // and the removed `server`/`chat`/`app` names: those execute as
            // a teaching failure (see `unknownScopeFailure`) — sections
            // redirect to osaurus_config export/apply, removed names get an
            // honest "Settings UI only" answer — instead of a generic
            // schema rejection the model would loop on.
            "scope": .object([
                "type": .string("string"),
                "enum": .array([
                    .string("agents"), .string("models"), .string("providers"),
                    .string("mcp"), .string("plugins"), .string("schedules"),
                    .string("skills"), .string("watchers"), .string("knowledge"),
                    .string("themes"), .string("commands"), .string("channels"),
                    .string("search"),
                    .string("mcp_servers"), .string("knowledge_collections"),
                    .string("search_providers"),
                    .string("server"), .string("chat"), .string("app"),
                    .string("memory"), .string("default_agent"),
                    .string("active_agent"), .string("tools"), .string("delegation"),
                ]),
                "description": .string(
                    "Configuration scope. Required for list and describe. memory, "
                        + "default_agent, active_agent, tools, and delegation are settings "
                        + "document sections — list/describe returns the section's current "
                        + "values (change them with osaurus_config apply). server, chat, and "
                        + "app are Settings-UI-only."),
            ]),
            "id": .object([
                "type": .string("string"),
                "description": .string(
                    "Item id, or its exact name (case-insensitive). Required for describe."),
            ]),
            "filter": .object([
                "type": .string("string"),
                "description": .string("Scope-specific list filter. See description."),
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
        let actionReq = requireAction(args, allowed: ["status", "list", "describe"])
        guard case .value(let action) = actionReq else { return actionReq.failureEnvelope ?? "" }

        switch action {
        case "status":
            return await statusEnvelope()
        case "list":
            return await listEnvelope(args)
        case "describe":
            return await describeEnvelope(args)
        default:
            return actionReq.failureEnvelope ?? ""
        }
    }

    // MARK: action: status

    private func statusEnvelope() async -> String {
        // Skills and knowledge collections load from disk off the main
        // actor (async store APIs), so gather their counts before the hop.
        let skillCount = await SkillStore.loadAll().count
        let knowledgeCollections = await KnowledgeCollectionStore.loadAllAsync()
        let knowledgeEnabledCount = knowledgeCollections.filter { $0.isEnabled }.count
        let knowledgeTotalCount = knowledgeCollections.count

        // The agent-facing reads below take `PluginRepositoryService.plugins`
        // as-is, but every caller of its `refresh()` is a view and the
        // auto-refresh timer follows that view's lifecycle. In a session where
        // nobody opened the Plugins tab the array is empty or stale, so
        // installed plugins were reported as missing and the model could not
        // invoke them (#2039). Local disk only; no repository/network I/O.
        await PluginRepositoryService.shared.ensureInstalledPluginsLoaded()

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
                    "No providers or local models configured — call osaurus_inspect({action: 'list', scope: 'models', filter: 'recommended'}) for top picks."
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
                suggestions.append(
                    "\(downloadingModels.count) model(s) downloading — poll osaurus_inspect({action: 'status'}) again.")
            }

            let snapshot: [String: Any] = [
                "active_agent": [
                    "id": activeAgentId.uuidString,
                    "name": activeAgent?.displayName ?? "Default",
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
            return ConfigurationReadNextStep.statusSuccess(tool: name, result: snapshot)
        }
        return envelope
    }

    // MARK: action: list

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

    private func listEnvelope(_ args: [String: Any]) async -> String {
        // Observed dead end: models put the scope name into `filter` and omit
        // `scope` ({action: 'list', filter: 'plugins'}). The intent is
        // unambiguous, so execute the intended list instead of rejecting —
        // the earlier reject-and-teach still left small models fabricating a
        // result rather than retrying the corrected call. A note in the
        // envelope names the canonical shape for next time.
        var args = args
        var filterAsScopeNote: String?
        if args["scope"] == nil,
            let misplaced = (args["filter"] as? String)?.lowercased(),
            Self.knownReadScopes.contains(Self.canonicalScope(misplaced))
        {
            args["scope"] = misplaced
            args.removeValue(forKey: "filter")
            filterAsScopeNote =
                "`\(misplaced)` is a scope, not a filter — it was treated as "
                + "{action: 'list', scope: '\(misplaced)'}. Pass `scope` directly next time."
        }
        let envelope = await resolvedListEnvelope(args)
        if let note = filterAsScopeNote {
            return Self.addingNote(note, toSuccessEnvelope: envelope)
        }
        return envelope
    }

    /// Inject a top-level `note` into a success envelope (no-op for error
    /// envelopes or unparseable strings, which pass through untouched).
    static func addingNote(_ note: String, toSuccessEnvelope envelope: String) -> String {
        guard let data = envelope.data(using: .utf8),
            var object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            object["ok"] as? Bool == true
        else { return envelope }
        object["note"] = note
        guard
            let out = try? JSONSerialization.data(
                withJSONObject: object,
                options: [.sortedKeys]
            ),
            let string = String(data: out, encoding: .utf8)
        else { return envelope }
        return string
    }

    private func resolvedListEnvelope(_ args: [String: Any]) async -> String {
        let scopeReq = requireString(args, "scope", expected: "scope name", tool: name)
        guard case .value(let rawScope) = scopeReq else { return scopeReq.failureEnvelope ?? "" }
        let filter = (args["filter"] as? String)?.lowercased() ?? ""

        // Section-name aliases: these declarative section ids double as
        // natural scope guesses, so they resolve to the matching read scope
        // instead of a redirect.
        let scope = Self.canonicalScope(rawScope)

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
            return ConfigurationReadNextStep.success(
                tool: name,
                result: [
                    "scope": "skills", "filter": filter,
                    "items": Self.filterByOrigin(items, filter: filter),
                ],
                scope: "skills"
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
            return ConfigurationReadNextStep.success(
                tool: name,
                result: [
                    "scope": "knowledge", "filter": filter,
                    "items": Self.filterByEnabledConnected(items, filter: filter),
                ],
                scope: "knowledge"
            )
        default:
            break
        }

        // The agent-facing reads below take `PluginRepositoryService.plugins`
        // as-is, but every caller of its `refresh()` is a view and the
        // auto-refresh timer follows that view's lifecycle. In a session where
        // nobody opened the Plugins tab the array is empty or stale, so
        // installed plugins were reported as missing and the model could not
        // invoke them (#2039). Local disk only; no repository/network I/O.
        if scope == "plugins" {
            await PluginRepositoryService.shared.ensureInstalledPluginsLoaded()
        }

        // A document-section name (`memory`, `default_agent`, …) is read
        // here, before the entity switch, so the enum's promise holds.
        if !Self.knownReadScopes.contains(scope),
            let read = await Self.documentSectionRead(scope: scope, tool: name)
        {
            return read
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
                    "note": "Rank 1 is tried first; lower ranks are fallbacks. Use osaurus_config to modify.",
                ]
            default:
                return Self.unknownScopeFailure(scope: scope, tool: name)
            }
            return ConfigurationReadNextStep.success(tool: name, result: payload, scope: scope)
        }
        return envelope
    }

    /// A settings DOCUMENT SECTION named as an inspect scope (`memory`,
    /// `default_agent`, `tools`, …) is answered with that section's current
    /// values — the same read `osaurus_config {action: 'export', sections:
    /// [x]}` performs — instead of a rejection. The scope enum advertises
    /// these names (compact-schema models see only the enum), the validator's
    /// own rejection for a junk scope lists them as allowed, and then the
    /// old execution path refused them as "not an inspect scope": a
    /// self-contradicting contract. Live (build #13, Raptor as Orchestrator):
    /// `scope: user_profile` → rejection listing `default_agent` → `scope:
    /// default_agent` → "not an inspect scope" → the identical call 29 times
    /// to the attempt cap. Reading the section is what the call meant.
    /// Returns nil for anything that is not a document section.
    static func documentSectionRead(scope: String, tool: String) async -> String? {
        guard let section = ConfigSectionID(rawValue: scope.lowercased()),
            !settingsUIOnlyScopes.contains(scope.lowercased())
        else { return nil }
        let document = await MainActor.run { ConfigExporter.export(sections: [section]) }
        let yaml: String
        do {
            yaml = try ConfigYAML.encode(document)
        } catch {
            return nil
        }
        return ConfigurationReadNextStep.success(
            tool: tool,
            result: [
                "scope": section.rawValue,
                "kind": "document_section",
                "format": "yaml",
                "yaml": yaml,
                "note":
                    "`\(section.rawValue)` is a configuration document section (read-only here). "
                    + "Change it with osaurus_config {action: 'apply', yaml: ...}.",
            ],
            scope: section.rawValue)
    }

    // MARK: action: describe

    private func describeEnvelope(_ args: [String: Any]) async -> String {
        let scopeReq = requireString(args, "scope", expected: "scope name", tool: name)
        guard case .value(let rawScope) = scopeReq else { return scopeReq.failureEnvelope ?? "" }
        let scope = Self.canonicalScope(rawScope)
        guard Self.knownReadScopes.contains(scope) else {
            // A document-section name reads the section (see
            // `documentSectionRead`); anything else keeps the teaching
            // failure so the model is not dead-ended on "no item matched".
            if let read = await Self.documentSectionRead(scope: scope, tool: name) { return read }
            return Self.unknownScopeFailure(scope: scope, tool: name)
        }
        // Observed dead end: describe without `id` fails generically and the
        // model gives up on the scope. Route the browse intent to list.
        if args["id"] == nil {
            return ToolEnvelope.failure(
                kind: .invalidArgs,
                message: "`describe` needs `id` (an entry's name or id). To browse the "
                    + "entries first, call {action: 'list', scope: '\(scope)'}.",
                tool: name)
        }
        let idReq = requireString(args, "id", expected: "identifier", tool: name)
        guard case .value(let idStr) = idReq else { return idReq.failureEnvelope ?? "" }
        return await describeItem(scope: scope, idStr: idStr)
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
        + "osaurus_inspect instead."
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
            return ConfigurationReadNextStep.success(
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
            return ConfigurationReadNextStep.success(
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

// MARK: - describe implementation

extension OsaurusInspectTool {

    fileprivate func describeItem(scope: String, idStr: String) async -> String {
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
            return ConfigurationReadNextStep.success(tool: name, result: result, scope: "skills")
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
            return ConfigurationReadNextStep.success(
                tool: name,
                result: [
                    "scope": "knowledge",
                    "id": collection.id.uuidString,
                    "name": collection.name,
                    "summary": collection.summary,
                    "folder_path": collection.folderPath,
                    "enabled": collection.isEnabled,
                    "git_remote_url": collection.gitRemoteURL ?? "",
                ],
                scope: "knowledge"
            )
        default:
            break
        }

        // The agent-facing reads below take `PluginRepositoryService.plugins`
        // as-is, but every caller of its `refresh()` is a view and the
        // auto-refresh timer follows that view's lifecycle. In a session where
        // nobody opened the Plugins tab the array is empty or stale, so
        // installed plugins were reported as missing and the model could not
        // invoke them (#2039). Local disk only; no repository/network I/O.
        if scope == "plugins" {
            await PluginRepositoryService.shared.ensureInstalledPluginsLoaded()
        }

        let envelope: String = await MainActor.run {
            let payload: [String: Any]?
            switch scope {
            case "agents":
                let uuid = UUID(uuidString: idStr)
                if let agent = AgentManager.shared.agents.first(where: {
                    $0.id == uuid || $0.name.caseInsensitiveCompare(idStr) == .orderedSame
                }) {
                    // Key is `model` (not `default_model`) on purpose: it
                    // matches the osaurus_config document schema, so a model
                    // that reads this payload reuses the right key when it
                    // writes the change document.
                    payload = [
                        "id": agent.id.uuidString,
                        "name": agent.name,
                        "description": agent.description,
                        "system_prompt": agent.systemPrompt,
                        "model": agent.defaultModel ?? "",
                        "temperature": agent.temperature ?? 0,
                        "max_tokens": agent.maxTokens ?? 0,
                        "is_built_in": agent.isBuiltIn,
                        "capabilities": AgentCapabilitiesPayload.payload(for: agent),
                    ]
                } else {
                    payload = nil
                }
            case "models":
                if idStr.caseInsensitiveCompare("foundation") == .orderedSame {
                    // Observed dead end: a "switch to foundation" ask gets
                    // verified against installed models, comes back empty,
                    // and the model refuses a perfectly valid setting.
                    return ToolEnvelope.failure(
                        kind: .invalidArgs,
                        message:
                            "\"foundation\" is the built-in Apple Foundation on-device model, "
                            + "not an installed model entry. It is always available as a model "
                            + "VALUE: apply it directly (e.g. default_agent.model: foundation "
                            + "or agents[].model: foundation).",
                        field: "id",
                        tool: name
                    )
                }
                if let model = ModelManager.shared.availableModels.first(where: {
                    $0.id == idStr || $0.name.caseInsensitiveCompare(idStr) == .orderedSame
                })
                    ?? ModelManager.shared.suggestedModels.first(where: {
                        $0.id == idStr || $0.name.caseInsensitiveCompare(idStr) == .orderedSame
                    })
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
                let providerUUID = UUID(uuidString: idStr)
                if let p = ConfigurationProviderReadVisibility.visibleProviders()
                    .first(where: {
                        $0.id == providerUUID
                            || $0.name.caseInsensitiveCompare(idStr) == .orderedSame
                    })
                {
                    let state = RemoteProviderManager.shared.providerStates[p.id]
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
                        // Bare ids as the provider advertises them. Prepend
                        // `model_prefix` + "/" to reference one in config
                        // documents / agent model settings.
                        "model_prefix": RemoteProviderManager.pickerPrefix(for: p.name),
                        "discovered_models": state?.discoveredModels ?? [],
                    ]
                } else {
                    payload = nil
                }
            case "mcp", "mcp_providers":
                let mcpUUID = UUID(uuidString: idStr)
                if let p = MCPProviderManager.shared.configuration.providers.first(where: {
                    $0.id == mcpUUID || $0.name.caseInsensitiveCompare(idStr) == .orderedSame
                }) {
                    let state = MCPProviderManager.shared.providerStates[p.id]
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
                let scheduleUUID = UUID(uuidString: idStr)
                if let s = ScheduleManager.shared.schedules.first(where: {
                    $0.id == scheduleUUID || $0.name.caseInsensitiveCompare(idStr) == .orderedSame
                }) {
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
                let watcherUUID = UUID(uuidString: idStr)
                if let w = WatcherStore.loadAll().first(where: {
                    $0.id == watcherUUID || $0.name.caseInsensitiveCompare(idStr) == .orderedSame
                }) {
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
            return ConfigurationReadNextStep.success(tool: name, result: result, scope: scope)
        }
        return envelope
    }

    private static func notFoundFailure(scope: String, id: String, tool: String) -> String {
        ToolEnvelope.failure(
            kind: .invalidArgs,
            message: "No `\(scope)` matched `\(id)` (by id or exact name). "
                + "Use {action: \"list\", scope: \"\(scope)\"} to see what exists.",
            tool: tool
        )
    }

    /// Every read scope `list` / `describe` accept. Kept in one place so the
    /// unknown-scope failure and the describe pre-check can't drift from the
    /// switch statements.
    static let knownReadScopes: Set<String> = [
        "agents", "models", "providers", "mcp", "mcp_providers", "plugins",
        "schedules", "skills", "watchers", "knowledge", "themes", "commands",
        "channels", "search",
    ]

    /// Declarative entity-section ids that double as natural scope guesses.
    /// They resolve to the matching read scope so a model that learned the
    /// section roster gets live rows, not a redirect.
    static func canonicalScope(_ scope: String) -> String {
        switch scope {
        case "mcp_servers": return "mcp"
        case "knowledge_collections": return "knowledge"
        case "search_providers": return "search"
        default: return scope
        }
    }

    /// Section names removed from the declarative surface in scope
    /// reduction 2. A model guessing these gets an honest "Settings UI
    /// only" answer instead of an export redirect it would loop on.
    static let settingsUIOnlyScopes: Set<String> = ["server", "chat", "app"]

    /// Unknown-scope failure that TEACHES instead of just rejecting. Small
    /// models guess document-section names (`tools`, `memory`,
    /// `delegation`, …) as inspect scopes and then loop on a bare "must be
    /// one of" error; when the guess IS a declarative section, the failure
    /// routes them to `osaurus_config` export/apply, which is the real way
    /// to read and change those settings. The removed `server`/`chat`/`app`
    /// names get an honest not-declarative answer.
    static func unknownScopeFailure(scope: String, tool: String) -> String {
        let valid =
            "agents, models, providers, mcp, plugins, schedules, skills, watchers, "
            + "knowledge, themes, commands, channels, search"
        if settingsUIOnlyScopes.contains(scope.lowercased()) {
            return ToolEnvelope.failure(
                kind: .invalidArgs,
                message:
                    "`\(scope)` settings are managed in the Settings UI, not declaratively — "
                    + "there is nothing to read or apply here. Tell the user to open "
                    + "Settings for \(scope) changes; do NOT claim to have changed anything. "
                    + "Inspect scopes: \(valid).",
                field: "scope",
                tool: tool
            )
        }
        if let section = ConfigSectionID(rawValue: scope.lowercased()) {
            return ToolEnvelope.failure(
                kind: .invalidArgs,
                message:
                    "`\(scope)` is a configuration DOCUMENT SECTION, not an inspect scope. "
                    + "Read its current values with osaurus_config {action: 'export', "
                    + "sections: ['\(section.rawValue)']}, then change it with osaurus_config "
                    + "{action: 'apply', yaml: ...}. Inspect scopes: \(valid).",
                field: "scope",
                tool: tool
            )
        }
        return ToolEnvelope.failure(
            kind: .invalidArgs,
            message: "Unknown scope `\(scope)`. Valid: \(valid).",
            field: "scope",
            tool: tool
        )
    }
}
