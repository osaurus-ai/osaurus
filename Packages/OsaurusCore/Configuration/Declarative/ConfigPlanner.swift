//
//  ConfigPlanner.swift
//  osaurus
//
//  Diffs an `OsaurusConfigDocument` against current Osaurus state and
//  produces a `ConfigPlan`. Merge-by-default: only sections present in
//  the document are considered, and within entity sections (agents,
//  mcp_servers, models, plugins, providers, schedules, watchers) only
//  listed entries change — unless `prune` is set, which additionally
//  deletes unlisted entries of the DECLARED sections.
//
//  Validation is all-or-nothing: any invalid reference or value fails
//  the whole plan with every issue listed, so a bad document can never
//  land a half-applied change.
//

import Foundation
@preconcurrency import MLXLMCommon

/// Fatal validation outcome: the document cannot be planned/applied.
public struct ConfigPlanIssues: Error, Equatable, Sendable {
    public let issues: [String]
}

/// Shared risk strings so planner and apply gate agree exactly.
/// Server-owned gates (network exposure, proxy, memory safety, body-size
/// raises) left with the `server` section in scope reduction 2.
enum ConfigRisk {
    static func autoPolicy(_ tool: String) -> String {
        "Sets tool `\(tool)` to auto — it will run without asking."
    }
    static func computerUse(_ agent: String) -> String {
        "Gives agent `\(agent)` screen control (computer use)."
    }
    static func browserUse(_ agent: String) -> String {
        "Gives agent `\(agent)` browser automation."
    }
    static func relayEnabled(_ agent: String) -> String {
        "Exposes agent `\(agent)` through the relay tunnel (reachable from outside this Mac)."
    }
    static func alwaysAllowSubagent(_ kind: String) -> String {
        "Sets subagent kind `\(kind)` to always_allow — its jobs run without asking."
    }
    static let applescriptAutoRun =
        "AppleScript automations auto-run with only a warning (no per-script confirmation)."
    static let ramPreflightDisabled =
        "Disables the RAM-safety preflight for spawned subagent jobs."
    static func mcpEndpoint(_ name: String, _ url: String) -> String {
        "Registers external MCP endpoint for `\(name)`: \(url)"
    }
    static func mcpRetarget(_ name: String, from: String, to: String) -> String {
        "Moves MCP server `\(name)` from \(from) to \(to)."
    }
    static func stdioCommand(_ name: String, _ command: String) -> String {
        "MCP server `\(name)` will launch a local process: \(command)"
    }
    static func stdioOnHost(_ name: String) -> String {
        "MCP server `\(name)` runs its process on the HOST, outside the sandbox."
    }
    static let channelWritesGlobal =
        "Re-enables the global channel write kill switch — agents may send on every "
        + "write-enabled platform again."
    static func channelWrites(_ platform: String) -> String {
        "Lets agents SEND messages on \(platform) (to its write allowlist)."
    }
    static func channelAutoReply(_ platform: String) -> String {
        "Inbound \(platform) messages get replies without per-message confirmation."
    }
    static func deleteCommand(_ name: String) -> String {
        "Deletes slash command `/\(name)` (prune)."
    }
    static func deleteKnowledgeCollection(_ name: String) -> String {
        "Deletes knowledge collection `\(name)` and its search index (prune). "
        + "Documents in the folder are not touched."
    }
    static func deleteAgent(_ name: String) -> String {
        "Deletes agent `\(name)` (prune)."
    }
    static func deleteModel(_ id: String) -> String {
        "Deletes model `\(id)` from disk (prune)."
    }
    static func deleteProvider(_ name: String) -> String {
        "Removes provider `\(name)` and its stored credentials (prune)."
    }
    static func uninstallPlugin(_ id: String) -> String {
        "Uninstalls plugin `\(id)` (prune)."
    }
    static func deleteMCPServer(_ name: String) -> String {
        "Removes MCP server `\(name)` and its tools (prune)."
    }
    static func deleteSchedule(_ name: String) -> String {
        "Deletes schedule `\(name)` (prune)."
    }
    static func deleteWatcher(_ name: String) -> String {
        "Deletes watcher `\(name)` (prune)."
    }
    static func deleteSearchProvider(_ id: String) -> String {
        "Removes search provider `\(id)` and its stored key (prune)."
    }
}

@MainActor
enum ConfigPlanner {

    /// Build the plan. Throws `ConfigPlanIssues` when the document is
    /// invalid (every issue listed at once).
    static func plan(document: OsaurusConfigDocument, prune: Bool) throws -> ConfigPlan {
        var issues: [String] = []
        validate(document: document, prune: prune, into: &issues)
        if prune { validatePruneAgentReferences(document: document, into: &issues) }
        if !issues.isEmpty { throw ConfigPlanIssues(issues: issues) }

        // Post-validation, every model reference resolves; rewrite them to
        // canonical form so the plan shows exactly what apply will store
        // (e.g. bare `claude-x` -> `anthropic/claude-x`).
        let document = normalizedModelReferences(in: document)

        let current = ConfigExporter.export()
        var actions: [ConfigPlanAction] = []
        var notes: [String] = []

        if let section = document.memory {
            planMemory(section, current: current.memory, into: &actions)
        }
        if let section = document.defaultAgent {
            planDefaultAgent(section, current: current.defaultAgent, into: &actions)
        }
        if let entries = document.agents {
            planAgents(entries, prune: prune, into: &actions, notes: &notes)
        }
        if let name = document.activeAgent {
            planActiveAgent(name, current: current.activeAgent ?? "default", into: &actions)
        }
        if let section = document.tools {
            planTools(section, into: &actions, notes: &notes)
        }
        if let section = document.delegation {
            planDelegation(section, current: current.delegation, into: &actions)
        }
        if let entries = document.commands {
            planCommands(entries, prune: prune, into: &actions)
        }
        if let entries = document.knowledgeCollections {
            planKnowledgeCollections(entries, prune: prune, into: &actions)
        }
        if let section = document.channels {
            planChannels(section, current: current.channels, into: &actions)
        }
        if let entries = document.mcpServers {
            planMCPServers(entries, prune: prune, into: &actions)
        }
        if let models = document.models {
            planModels(models, prune: prune, into: &actions, notes: &notes)
        }
        if let plugins = document.plugins {
            planPlugins(plugins, prune: prune, into: &actions)
        }
        if let entries = document.providers {
            planProviders(entries, prune: prune, into: &actions, notes: &notes)
        }
        if let section = document.searchProviders {
            planSearchProviders(section, prune: prune, into: &actions)
        }
        if let entries = document.schedules {
            planSchedules(entries, document: document, prune: prune, into: &actions)
        }
        if let entries = document.watchers {
            planWatchers(entries, document: document, prune: prune, into: &actions)
        }

        return ConfigPlan(actions: actions, notes: notes)
    }

    // MARK: - Validation

    /// Names of custom agents that will exist after apply: current custom
    /// agents plus any created by the document. Used to validate schedule /
    /// watcher / active_agent references. When `prune` is set and the
    /// document declares `agents:`, unlisted current agents are DELETED by
    /// apply, so only the document's names count as post-apply state.
    private static func effectiveAgentNames(
        document: OsaurusConfigDocument, prune: Bool
    ) -> Set<String> {
        let docNames = Set((document.agents ?? []).map { $0.name.lowercased() })
        if prune, document.agents != nil {
            return docNames
        }
        var names = Set(
            AgentManager.shared.agents
                .filter { !$0.isBuiltIn }
                .map { $0.name.lowercased() }
        )
        names.formUnion(docNames)
        return names
    }

    /// Prune-only integrity check: pruning `agents:` deletes every custom
    /// agent the document does not list — but `AgentManager.delete` does NOT
    /// cascade schedules/watchers (it only resets the active-agent selection
    /// to Default). Refuse a document whose prune would leave a SURVIVING
    /// schedule or watcher pointing at a deleted agent: the user must delete
    /// or reassign it in the same document.
    private static func validatePruneAgentReferences(
        document: OsaurusConfigDocument, into issues: inout [String]
    ) {
        guard let docAgents = document.agents else { return }
        let keptNames = Set(docAgents.map { $0.name.lowercased() })
        let pruned = AgentManager.shared.agents.filter {
            !$0.isBuiltIn && !keptNames.contains($0.name.lowercased())
        }
        guard !pruned.isEmpty else { return }
        let prunedNameById = Dictionary(
            pruned.map { ($0.id, $0.name) },
            uniquingKeysWith: { first, _ in first }
        )

        // A schedule/watcher survives when its section is absent (merge
        // semantics leave it alone) or when it is listed in the document
        // (prune only deletes UNLISTED entries). A listed entry that
        // explicitly reassigns `agent` is already validated against the
        // post-apply agent set by the regular reference checks.
        let listedSchedules: [String: ScheduleEntry]? = document.schedules.map { entries in
            Dictionary(
                entries.map { ($0.name.lowercased(), $0) },
                uniquingKeysWith: { first, _ in first }
            )
        }
        for schedule in ScheduleManager.shared.schedules {
            guard let agentId = schedule.agentId,
                let agentName = prunedNameById[agentId]
            else { continue }
            if let listed = listedSchedules {
                guard let entry = listed[schedule.name.lowercased()] else { continue }
                guard entry.agent == nil else { continue }
            }
            issues.append(
                "prune: schedule `\(schedule.name)` still runs on agent `\(agentName)`, "
                    + "which this prune would delete. Delete or reassign the schedule "
                    + "in the same document.")
        }

        let listedWatchers: [String: WatcherEntry]? = document.watchers.map { entries in
            Dictionary(
                entries.map { ($0.name.lowercased(), $0) },
                uniquingKeysWith: { first, _ in first }
            )
        }
        for watcher in WatcherManager.shared.watchers {
            guard let agentId = watcher.agentId,
                let agentName = prunedNameById[agentId]
            else { continue }
            if let listed = listedWatchers {
                guard let entry = listed[watcher.name.lowercased()] else { continue }
                guard entry.agent == nil else { continue }
            }
            issues.append(
                "prune: watcher `\(watcher.name)` still runs on agent `\(agentName)`, "
                    + "which this prune would delete. Delete or reassign the watcher "
                    + "in the same document.")
        }
    }

    /// Agent model ids must resolve to something the chat runtime can route:
    /// `foundation`, an installed local bundle id, or a provider-prefixed
    /// cloud id. A bare cloud id that exactly one provider offers is fine
    /// (apply auto-prefixes it); anything unresolvable is an issue, because
    /// storing it would silently leave the agent without a working model.
    /// EXCEPT a value equal to what is already stored: exports must re-apply
    /// even when a stored model has gone stale (provider removed, model
    /// uninstalled), so only new or changed references are grounded.
    private static func validateModelReferences(
        document: OsaurusConfigDocument, into issues: inout [String]
    ) {
        let catalog = ConfigModelReference.liveCatalog()
        let pending = document.models ?? []
        func check(_ field: ConfigField<String>, current: String?, label: String) {
            guard let value = field.valueOrNil?.trimmingCharacters(in: .whitespacesAndNewlines),
                !value.isEmpty
            else { return }
            if let current, current.caseInsensitiveCompare(value) == .orderedSame { return }
            if case .invalid(let message) = ConfigModelReference.resolve(
                value, catalog: catalog, pendingLocalIds: pending)
            {
                issues.append("\(label): \(message)")
            }
        }
        if let section = document.defaultAgent {
            check(
                section.model,
                current: DefaultAgentConfigurationStore.load().defaultModel,
                label: "default_agent.model")
        }
        let existingAgents = AgentManager.shared.agents.filter { !$0.isBuiltIn }
        for entry in document.agents ?? [] {
            let existing = existingAgents.first {
                $0.name.lowercased() == entry.name.lowercased()
            }
            check(
                entry.model, current: existing?.defaultModel,
                label: "agents[\(entry.name)].model")
        }
    }

    /// Rewrite every resolvable model reference to its canonical id. Called
    /// after validation, so failures cannot occur here; unresolvable values
    /// (only possible if state changed mid-plan) are left untouched and
    /// re-checked at apply time.
    private static func normalizedModelReferences(
        in document: OsaurusConfigDocument
    ) -> OsaurusConfigDocument {
        let catalog = ConfigModelReference.liveCatalog()
        let pending = document.models ?? []
        func canonical(_ field: ConfigField<String>) -> ConfigField<String> {
            guard let value = field.valueOrNil else { return field }
            if case .resolved(let id) = ConfigModelReference.resolve(
                value, catalog: catalog, pendingLocalIds: pending)
            {
                return .value(id)
            }
            return field
        }
        var document = document
        if var section = document.defaultAgent {
            section.model = canonical(section.model)
            document.defaultAgent = section
        }
        if let agents = document.agents {
            document.agents = agents.map { entry in
                var entry = entry
                entry.model = canonical(entry.model)
                return entry
            }
        }
        return document
    }

    private static func validate(
        document: OsaurusConfigDocument, prune: Bool, into issues: inout [String]
    ) {
        if let version = document.version, version != 1 {
            issues.append("version: only schema version 1 is supported (got \(version)).")
        }

        if let memory = document.memory {
            if let v = memory.budgetTokens, !(100...4000).contains(v) {
                issues.append("memory.budget_tokens: must be in 100...4000.")
            }
            if let v = memory.retentionDays, !(0...3650).contains(v) {
                issues.append("memory.retention_days: must be in 0...3650 (0 = forever).")
            }
        }
        if let section = document.defaultAgent {
            checkRange(section.temperature, 0.0...2.0, "default_agent.temperature", &issues)
            checkRange(section.maxTokens, 1...10_000_000, "default_agent.max_tokens", &issues)
        }

        if let agents = document.agents {
            var seen = Set<String>()
            for entry in agents {
                let key = entry.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                if key.isEmpty {
                    issues.append("agents[]: every agent needs a non-empty name.")
                    continue
                }
                if key == "default" {
                    issues.append(
                        "agents[\(entry.name)]: the Default agent is configured via the "
                            + "`default_agent` section, not `agents`.")
                }
                if !seen.insert(key).inserted {
                    issues.append("agents[\(entry.name)]: duplicate agent name in document.")
                }
                checkRange(entry.temperature, 0.0...2.0, "agents[\(entry.name)].temperature", &issues)
                checkRange(entry.maxTokens, 1...10_000_000, "agents[\(entry.name)].max_tokens", &issues)
                if let ids = entry.capabilities?.knowledgeCollectionIds {
                    for raw in ids where UUID(uuidString: raw) == nil {
                        issues.append(
                            "agents[\(entry.name)].capabilities.knowledge_collection_ids: "
                                + "`\(raw)` is not a UUID.")
                    }
                }
                // A doc name colliding with a built-in (non-default) agent
                // would silently patch it; refuse instead.
                if let existing = AgentManager.shared.agents.first(where: {
                    $0.name.lowercased() == key
                }), existing.isBuiltIn {
                    issues.append(
                        "agents[\(entry.name)]: `\(existing.name)` is a built-in agent and "
                            + "cannot be managed declaratively.")
                }
            }
        }

        if let active = document.activeAgent {
            let key = active.lowercased()
            if key != "default" && !effectiveAgentNames(document: document, prune: prune).contains(key) {
                issues.append(
                    "active_agent: no agent named `\(active)` exists or is created by this document.")
            }
        }

        validateModelReferences(document: document, into: &issues)

        if let tools = document.tools, let policies = tools.policies {
            for (tool, raw) in policies {
                if ToolPermissionPolicy(rawValue: raw.lowercased()) == nil {
                    issues.append("tools.policies[\(tool)]: must be one of: auto, ask, deny.")
                }
            }
        }

        if let section = document.delegation {
            checkEnum(
                section.applescriptExecutionMode,
                ConfigAppBehaviorEnums.applescriptExecutionModes,
                "delegation.applescript_execution_mode", &issues)
            checkEnum(
                section.spawnToolAccess, ConfigAppBehaviorEnums.spawnToolAccessValues,
                "delegation.spawn_tool_access", &issues)
            for (kind, raw) in (section.permissionDefaults ?? [:]).sorted(by: { $0.key < $1.key }) {
                if !ConfigAppBehaviorEnums.permissionKindIds.contains(kind.lowercased()) {
                    issues.append(
                        "delegation.permission_defaults[\(kind)]: unknown kind — one of: "
                            + ConfigAppBehaviorEnums.permissionKindIds.joined(separator: ", ") + ".")
                }
                if !ConfigAppBehaviorEnums.permissionPolicies.contains(raw.lowercased()) {
                    issues.append(
                        "delegation.permission_defaults[\(kind)]: must be one of: "
                            + ConfigAppBehaviorEnums.permissionPolicies.joined(separator: ", ") + ".")
                }
            }
            func checkBudget(_ value: Int?, _ bounds: ClosedRange<Int>, _ label: String) {
                if let value, !bounds.contains(value) {
                    issues.append(
                        "delegation.\(label): must be in "
                            + "\(bounds.lowerBound)...\(bounds.upperBound).")
                }
            }
            checkBudget(section.budgetMaxTokens, SubagentBudgets.tokenBounds, "budget_max_tokens")
            checkBudget(section.budgetMaxTurns, SubagentBudgets.turnBounds, "budget_max_turns")
            checkBudget(
                section.budgetMaxToolCalls, SubagentBudgets.toolCallBounds, "budget_max_tool_calls")
            checkBudget(
                section.budgetMaxSeconds, SubagentBudgets.elapsedBounds, "budget_max_seconds")
            checkBudget(
                section.budgetMaxParallelSpawns, SubagentBudgets.parallelSpawnBounds,
                "budget_max_parallel_spawns")
            // Spawn targets may be custom agents (existing or created by this
            // document) or built-in library agents — never the Default agent.
            var spawnTargets = effectiveAgentNames(document: document, prune: prune)
            spawnTargets.formUnion(
                AgentManager.shared.agents.filter { $0.isBuiltIn }.map { $0.name.lowercased() })
            for name in section.spawnableAgents ?? [] {
                let key = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                if key == "default" {
                    issues.append(
                        "delegation.spawnable_agents: the Default agent cannot spawn itself.")
                } else if !spawnTargets.contains(key) {
                    issues.append(
                        "delegation.spawnable_agents: no agent named `\(name)` exists or is "
                            + "created by this document.")
                }
            }
        }

        if let commands = document.commands {
            var seen = Set<String>()
            let existing = ConfigExporter.manageableCommands()
            let reserved = Set(SlashCommand.builtIns.map { $0.name.lowercased() })
            for entry in commands {
                let key = entry.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                if key.isEmpty {
                    issues.append("commands[]: every command needs a non-empty name.")
                    continue
                }
                if !seen.insert(key).inserted {
                    issues.append("commands[\(entry.name)]: duplicate command name in document.")
                }
                // Name-shape rules gate CREATES only, so a full export always
                // re-plans clean even if odd names already exist on disk.
                let isNew = !existing.contains { $0.name.lowercased() == key }
                guard isNew else { continue }
                if key.contains(where: { $0.isWhitespace }) || key.hasPrefix("/") {
                    issues.append(
                        "commands[\(entry.name)]: the name is typed as /name — no spaces or "
                            + "leading slash.")
                }
                if reserved.contains(key) {
                    issues.append(
                        "commands[\(entry.name)]: `/\(key)` is a built-in command and cannot "
                            + "be managed declaratively.")
                }
                if (entry.template ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    issues.append(
                        "commands[\(entry.name)]: `template` is required to create a command.")
                }
            }
        }

        if let collections = document.knowledgeCollections {
            var seen = Set<String>()
            let existing = KnowledgeCollectionStore.loadAll()
            for entry in collections {
                let key = entry.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                if key.isEmpty {
                    issues.append("knowledge_collections[]: every collection needs a non-empty name.")
                    continue
                }
                if !seen.insert(key).inserted {
                    issues.append(
                        "knowledge_collections[\(entry.name)]: duplicate collection name in document.")
                }
                let current = existing.first { $0.name.lowercased() == key }
                if current == nil && entry.folderPath == nil {
                    issues.append(
                        "knowledge_collections[\(entry.name)]: `folder_path` is required to create.")
                }
                if let raw = entry.folderPath {
                    let expanded = (raw as NSString).expandingTildeInPath
                    if let current {
                        if expanded != (current.folderPath as NSString).expandingTildeInPath {
                            issues.append(
                                "knowledge_collections[\(entry.name)].folder_path: immutable after "
                                    + "create — delete and re-add the collection to move it.")
                        }
                        // Existence gates CREATES only: an already-registered
                        // collection whose folder went missing must not make
                        // a full export un-plannable.
                    } else {
                        var isDirectory: ObjCBool = false
                        if !FileManager.default.fileExists(atPath: expanded, isDirectory: &isDirectory)
                            || !isDirectory.boolValue
                        {
                            issues.append(
                                "knowledge_collections[\(entry.name)].folder_path: `\(expanded)` is "
                                    + "not an existing directory.")
                        }
                    }
                }
            }
        }

        if let channels = document.channels {
            let customAgents = effectiveAgentNames(document: document, prune: prune)
            for platform in ConfigChannelPlatform.allCases {
                guard let section = platform.section(in: channels) else { continue }
                let label = "channels.\(platform.rawValue)"
                if let v = section.defaultReadLimit, !(1...100).contains(v) {
                    issues.append("\(label).default_read_limit: must be in 1...100.")
                }
                if let name = section.inboundAgent.valueOrNil {
                    let key = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                    if key == "default" || key.isEmpty {
                        issues.append(
                            "\(label).inbound_agent: channel dispatch needs a CUSTOM agent "
                                + "(never the Default agent); null clears it.")
                    } else if !customAgents.contains(key) {
                        issues.append(
                            "\(label).inbound_agent: no custom agent named `\(name)` exists or "
                                + "is created by this document.")
                    }
                }
                if let raw = section.botTokenRef {
                    if platform.supportsBotTokenRef {
                        validateSecretRef(raw, label: "\(label).bot_token_ref", into: &issues)
                    } else {
                        issues.append(
                            "\(label).bot_token_ref: \(platform.rawValue) has no bot token — "
                                + "iMessage needs none and WhatsApp links interactively.")
                    }
                }
                if let raw = section.appTokenRef {
                    if platform.supportsAppTokenRef {
                        validateSecretRef(raw, label: "\(label).app_token_ref", into: &issues)
                    } else {
                        issues.append("\(label).app_token_ref: only Slack uses an app-level token.")
                    }
                }
            }
        }

        if let servers = document.mcpServers {
            var seen = Set<String>()
            let existing = ConfigExporter.manageableMCPProviders()
            for entry in servers {
                let key = entry.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                if key.isEmpty {
                    issues.append("mcp_servers[]: every server needs a non-empty name.")
                    continue
                }
                if !seen.insert(key).inserted {
                    issues.append("mcp_servers[\(entry.name)]: duplicate server name in document.")
                }
                let current = existing.first { $0.name.lowercased() == key }

                // Effective transport: explicit key, else the existing
                // server's, else http. Immutable once created.
                let declared = entry.transport?.lowercased()
                if let declared, MCPProviderTransport(rawValue: declared) == nil {
                    issues.append("mcp_servers[\(entry.name)].transport: must be http or stdio.")
                    continue
                }
                if let current, let declared, declared != current.transport.rawValue {
                    issues.append(
                        "mcp_servers[\(entry.name)].transport: immutable after create — remove "
                            + "and re-add the server to change it.")
                    continue
                }
                let transport =
                    current?.transport
                    ?? declared.flatMap(MCPProviderTransport.init(rawValue:)) ?? .http

                switch transport {
                case .http:
                    if current == nil && entry.url == nil {
                        issues.append(
                            "mcp_servers[\(entry.name)]: `url` is required to add a new server.")
                    }
                    if let url = entry.url {
                        let scheme = URL(string: url)?.scheme?.lowercased()
                        if scheme != "http" && scheme != "https" {
                            issues.append(
                                "mcp_servers[\(entry.name)].url: must be a valid http(s) URL.")
                        }
                    }
                    if let auth = entry.auth, ConfigMCPAuth.auth(forKey: auth) == nil {
                        issues.append(
                            "mcp_servers[\(entry.name)].auth: must be one of: none, bearer, oauth.")
                    }
                    if entry.command != nil || entry.args != nil || entry.env != nil
                        || entry.workingDirectory != nil || entry.executionHost != nil
                        || entry.secretEnvRefs != nil
                    {
                        issues.append(
                            "mcp_servers[\(entry.name)]: command/args/env/working_directory/"
                                + "execution_host/secret_env_refs only apply to transport: stdio.")
                    }
                    if let raw = entry.tokenRef {
                        validateSecretRef(
                            raw, label: "mcp_servers[\(entry.name)].token_ref", into: &issues)
                        if entry.auth?.lowercased() == "oauth" {
                            issues.append(
                                "mcp_servers[\(entry.name)].token_ref: an oauth server signs in "
                                    + "interactively — token_ref only fits bearer auth.")
                        }
                    }
                case .stdio:
                    if current == nil,
                        (entry.command ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    {
                        issues.append(
                            "mcp_servers[\(entry.name)]: `command` is required to add a stdio "
                                + "server.")
                    }
                    if let host = entry.executionHost,
                        MCPProviderExecutionHost(rawValue: host.lowercased()) == nil
                    {
                        issues.append(
                            "mcp_servers[\(entry.name)].execution_host: must be sandbox or host.")
                    }
                    if entry.url != nil || entry.auth != nil || entry.tokenRef != nil {
                        issues.append(
                            "mcp_servers[\(entry.name)]: url/auth/token_ref only apply to "
                                + "transport: http.")
                    }
                    if let refs = entry.secretEnvRefs {
                        for (envKey, raw) in refs.sorted(by: { $0.key < $1.key }) {
                            if envKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                issues.append(
                                    "mcp_servers[\(entry.name)].secret_env_refs: env keys must "
                                        + "be non-empty.")
                                continue
                            }
                            validateSecretRef(
                                raw,
                                label: "mcp_servers[\(entry.name)].secret_env_refs[\(envKey)]",
                                into: &issues)
                        }
                    }
                }
            }
        }

        if let providers = document.providers {
            var seen = Set<String>()
            let existing = ConfigProviderPresets.manageableProviders()
            for entry in providers {
                let key = entry.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                if key.isEmpty {
                    issues.append("providers[]: every provider needs a non-empty name.")
                    continue
                }
                if !seen.insert(key).inserted {
                    issues.append("providers[\(entry.name)]: duplicate provider name in document.")
                }
                let current = existing.first { $0.name.lowercased() == key }
                if current == nil {
                    guard let raw = entry.provider else {
                        issues.append(
                            "providers[\(entry.name)]: `provider` is required to add a new provider. "
                                + "One of: \(ConfigProviderPresets.canonicalIdsList).")
                        continue
                    }
                    if ConfigProviderPresets.resolve(raw) == nil {
                        issues.append(
                            "providers[\(entry.name)].provider: must be one of: "
                                + ConfigProviderPresets.canonicalIdsList + ".")
                    }
                }
                if let raw = entry.providerProtocol,
                    RemoteProviderProtocol(rawValue: raw.lowercased()) == nil
                {
                    issues.append("providers[\(entry.name)].protocol: must be http or https.")
                }
                if case .value(let port) = entry.port, !(1...65535).contains(port) {
                    issues.append("providers[\(entry.name)].port: must be in 1...65535.")
                }
                if let v = entry.timeoutSeconds, !(1...600).contains(v) {
                    issues.append("providers[\(entry.name)].timeout_seconds: must be in 1...600.")
                }
                if let raw = entry.apiKeyRef {
                    validateSecretRef(
                        raw, label: "providers[\(entry.name)].api_key_ref", into: &issues)
                    if entry.setApiKey == true {
                        issues.append(
                            "providers[\(entry.name)]: use either set_api_key (interactive sheet) "
                                + "or api_key_ref (secret reference), not both.")
                    }
                    switch ConfigProviderPresets.resolve(entry.provider) {
                    case .codexOAuth, .osaurusAgent:
                        issues.append(
                            "providers[\(entry.name)].api_key_ref: `\(entry.provider ?? "")` signs "
                                + "in via OAuth/pairing — an API key does not apply.")
                    case .preset, nil:
                        break
                    }
                }
                // Endpoint fields are create-only: changing the endpoint of a
                // provider that holds a stored credential is the classic
                // bait-and-switch, so a mismatch refuses the document.
                if let current {
                    func refuse(_ field: String) {
                        issues.append(
                            "providers[\(entry.name)].\(field): the endpoint of an existing "
                                + "provider cannot be changed — remove and re-add the provider "
                                + "to move it.")
                    }
                    if let host = entry.host, host != current.host { refuse("host") }
                    if let raw = entry.providerProtocol,
                        raw.lowercased() != current.providerProtocol.rawValue
                    {
                        refuse("protocol")
                    }
                    if entry.port.isSpecified, entry.port.valueOrNil != current.port {
                        refuse("port")
                    }
                    if let basePath = entry.basePath, basePath != current.basePath {
                        refuse("base_path")
                    }
                }
            }
        }

        if let models = document.models {
            var seen = Set<String>()
            for id in models where !seen.insert(id.lowercased()).inserted {
                issues.append("models: duplicate model id `\(id)` in document.")
            }
        }
        if let plugins = document.plugins {
            var seen = Set<String>()
            for id in plugins where !seen.insert(id.lowercased()).inserted {
                issues.append("plugins: duplicate plugin id `\(id)` in document.")
            }
        }

        if let section = document.searchProviders {
            let manager = SearchProviderManager.shared
            var seen = Set<String>()
            for entry in section.providers ?? [] {
                if manager.definition(id: entry.id) == nil {
                    issues.append("search_providers.providers[\(entry.id)]: unknown provider id.")
                }
                if !seen.insert(entry.id.lowercased()).inserted {
                    issues.append(
                        "search_providers.providers[\(entry.id)]: duplicate provider id in document.")
                }
            }
            for id in section.ranking ?? [] {
                if manager.definition(id: id) == nil {
                    issues.append("search_providers.ranking: unknown provider id `\(id)`.")
                }
            }
        }

        let agentNames = effectiveAgentNames(document: document, prune: prune)

        if let schedules = document.schedules {
            var seen = Set<String>()
            let existing = ScheduleManager.shared.schedules
            for entry in schedules {
                let key = entry.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                if key.isEmpty {
                    issues.append("schedules[]: every schedule needs a non-empty name.")
                    continue
                }
                if !seen.insert(key).inserted {
                    issues.append("schedules[\(entry.name)]: duplicate schedule name in document.")
                }
                let isNew = !existing.contains { $0.name.lowercased() == key }
                if isNew {
                    if entry.agent == nil {
                        issues.append(
                            "schedules[\(entry.name)]: `agent` (custom agent name) is required to "
                                + "create a schedule.")
                    }
                    if entry.instructions == nil {
                        issues.append("schedules[\(entry.name)]: `instructions` is required to create.")
                    }
                    if entry.frequency == nil {
                        issues.append("schedules[\(entry.name)]: `frequency` is required to create.")
                    }
                }
                if let agent = entry.agent {
                    if agent.lowercased() == "default" {
                        issues.append(
                            "schedules[\(entry.name)].agent: schedules cannot target the Default agent.")
                    } else if !agentNames.contains(agent.lowercased()) {
                        issues.append(
                            "schedules[\(entry.name)].agent: no custom agent named `\(agent)` exists "
                                + "or is created by this document.")
                    }
                }
                if let frequency = entry.frequency {
                    if case .failure(let error) = ConfigScheduleFrequency.parse(
                        frequency: frequency,
                        value: entry.frequencyValue,
                        timeOfDay: entry.frequencyTimeOfDay
                    ) {
                        issues.append("schedules[\(entry.name)]: \(error.message)")
                    }
                }
            }
        }

        if let watchers = document.watchers {
            var seen = Set<String>()
            let existing = WatcherManager.shared.watchers
            for entry in watchers {
                let key = entry.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                if key.isEmpty {
                    issues.append("watchers[]: every watcher needs a non-empty name.")
                    continue
                }
                if !seen.insert(key).inserted {
                    issues.append("watchers[\(entry.name)]: duplicate watcher name in document.")
                }
                let isNew = !existing.contains { $0.name.lowercased() == key }
                if isNew {
                    if entry.agent == nil {
                        issues.append(
                            "watchers[\(entry.name)]: `agent` (custom agent name) is required to create.")
                    }
                    if entry.instructions == nil {
                        issues.append("watchers[\(entry.name)]: `instructions` is required to create.")
                    }
                    if entry.path == nil {
                        issues.append("watchers[\(entry.name)]: `path` is required to create.")
                    }
                }
                if let agent = entry.agent {
                    if agent.lowercased() == "default" {
                        issues.append(
                            "watchers[\(entry.name)].agent: watchers cannot run on the Default agent.")
                    } else if !agentNames.contains(agent.lowercased()) {
                        issues.append(
                            "watchers[\(entry.name)].agent: no custom agent named `\(agent)` exists "
                                + "or is created by this document.")
                    }
                }
                if let raw = entry.path {
                    let expanded = (raw as NSString).expandingTildeInPath
                    var isDirectory: ObjCBool = false
                    if !FileManager.default.fileExists(atPath: expanded, isDirectory: &isDirectory)
                        || !isDirectory.boolValue
                    {
                        issues.append(
                            "watchers[\(entry.name)].path: `\(expanded)` is not an existing directory.")
                    }
                }
                if let raw = entry.responsiveness, Responsiveness(rawValue: raw.lowercased()) == nil {
                    issues.append(
                        "watchers[\(entry.name)].responsiveness: must be one of: fast, balanced, "
                            + "patient, relaxed, deferred, extended.")
                }
            }
        }
    }

    private static func checkRange<T: Comparable & Sendable & Equatable>(
        _ field: ConfigField<T>, _ range: ClosedRange<T>, _ label: String, _ issues: inout [String]
    ) {
        if case .value(let v) = field, !range.contains(v) {
            issues.append("\(label): must be in \(range.lowerBound)...\(range.upperBound).")
        }
    }

    /// Case-insensitive membership check for string-enum document keys.
    private static func checkEnum(
        _ raw: String?, _ allowed: [String], _ label: String, _ issues: inout [String]
    ) {
        guard let raw else { return }
        if !allowed.contains(raw.lowercased()) {
            issues.append("\(label): must be one of: \(allowed.joined(separator: ", ")).")
        }
    }

    // MARK: - Scalar-section diff helpers

    /// Appends `key: old -> new` when the document specifies a different
    /// value than the current one.
    private static func diff<T: Equatable>(
        _ key: String, desired: T?, current: T?, into changes: inout [String]
    ) {
        guard let desired, desired != current else { return }
        changes.append("\(key): \(display(current)) -> \(display(desired))")
    }

    /// Secret references: reject a malformed ref, and fail fast when an env
    /// ref names a variable the app process cannot see. Keychain refs are
    /// only format-checked here — resolving one can show a macOS dialog,
    /// which planning must never trigger.
    private static func validateSecretRef(
        _ raw: String, label: String, into issues: inout [String]
    ) {
        switch ConfigSecretRef.parse(raw) {
        case .failure(let message):
            issues.append("\(label): \(message)")
        case .success(let ref):
            if let issue = ref.planTimeIssue(label: label) {
                issues.append(issue)
            }
        }
    }

    private static func diff<T: Equatable>(
        _ key: String, desired: ConfigField<T>, current: ConfigField<T>, into changes: inout [String]
    ) {
        switch desired {
        case .absent:
            return
        case .null:
            if case .null = current { return }
            changes.append("\(key): \(display(current.valueOrNil)) -> (cleared)")
        case .value(let v):
            if case .value(let c) = current, c == v { return }
            changes.append("\(key): \(display(current.valueOrNil)) -> \(display(v))")
        }
    }

    /// Double document fields mirror `Float`-typed live settings
    /// (temperatures, top_p): `Double(Float(0.7)) != 0.7`, so exact equality
    /// would flag a change for every hand-written decimal that round-trips
    /// through the Float store. Compare with a tolerance far below any
    /// meaningful sampler delta instead.
    private static func nearlyEqual(_ a: Double, _ b: Double) -> Bool {
        abs(a - b) <= 1e-6
    }

    private static func diff(
        _ key: String, desired: Double?, current: Double?, into changes: inout [String]
    ) {
        guard let desired else { return }
        if let current, nearlyEqual(desired, current) { return }
        changes.append("\(key): \(display(current)) -> \(display(desired))")
    }

    private static func diff(
        _ key: String, desired: ConfigField<Double>, current: ConfigField<Double>,
        into changes: inout [String]
    ) {
        switch desired {
        case .absent:
            return
        case .null:
            if case .null = current { return }
            changes.append("\(key): \(display(current.valueOrNil)) -> (cleared)")
        case .value(let v):
            if case .value(let c) = current, nearlyEqual(c, v) { return }
            changes.append("\(key): \(display(current.valueOrNil)) -> \(display(v))")
        }
    }

    private static func display<T>(_ value: T?) -> String {
        guard let value else { return "(unset)" }
        let text = String(describing: value)
        if text.count > 80 {
            return String(text.prefix(77)) + "..."
        }
        return text
    }

    /// Merge-map diff: only keys listed in the document are compared.
    /// `defaultValue` is what an absent current key means (nil -> "(unset)").
    private static func diffMap<T: Equatable>(
        _ prefix: String, desired: [String: T]?, current: [String: T]?,
        defaultValue: T? = nil, into changes: inout [String]
    ) {
        for (key, value) in (desired ?? [:]).sorted(by: { $0.key < $1.key }) {
            let currentValue = current?[key] ?? defaultValue
            guard currentValue != value else { continue }
            changes.append("\(prefix)[\(key)]: \(display(currentValue)) -> \(display(value))")
        }
    }

    /// Replace-list diff (`allowlist`, `spawnable_agents`, ...): the document
    /// value replaces the whole list, compared case-insensitively.
    private static func diffList(
        _ key: String, desired: [String]?, current: [String]?, into changes: inout [String]
    ) {
        guard let desired else { return }
        let currentList = current ?? []
        guard desired.map({ $0.lowercased() }) != currentList.map({ $0.lowercased() }) else {
            return
        }
        changes.append("\(key): \(display(currentList)) -> \(display(desired))")
    }

    // MARK: - Settings scopes

    private static func planMemory(
        _ desired: MemorySection, current: MemorySection?, into actions: inout [ConfigPlanAction]
    ) {
        let current = current ?? MemorySection()
        var changes: [String] = []
        diff("enabled", desired: desired.enabled, current: current.enabled, into: &changes)
        diff("budget_tokens", desired: desired.budgetTokens, current: current.budgetTokens, into: &changes)
        diff(
            "retention_days", desired: desired.retentionDays,
            current: current.retentionDays, into: &changes)
        guard !changes.isEmpty else { return }
        actions.append(
            ConfigPlanAction(section: "memory", target: "memory", kind: .update, changes: changes))
    }

    private static func planDefaultAgent(
        _ desired: DefaultAgentSection, current: DefaultAgentSection?,
        into actions: inout [ConfigPlanAction]
    ) {
        let current = current ?? DefaultAgentSection()
        var changes: [String] = []
        diff("name", desired: desired.name, current: current.name, into: &changes)
        diff("model", desired: desired.model, current: current.model, into: &changes)
        diff("temperature", desired: desired.temperature, current: current.temperature, into: &changes)
        diff("max_tokens", desired: desired.maxTokens, current: current.maxTokens, into: &changes)
        diff(
            "system_prompt", desired: desired.systemPrompt,
            current: current.systemPrompt, into: &changes)
        diff("disable_tools", desired: desired.disableTools, current: current.disableTools, into: &changes)
        guard !changes.isEmpty else { return }
        actions.append(
            ConfigPlanAction(
                section: "default_agent", target: "default_agent", kind: .update, changes: changes))
    }

    private static func planActiveAgent(
        _ desired: String, current: String, into actions: inout [ConfigPlanAction]
    ) {
        guard desired.lowercased() != current.lowercased() else { return }
        actions.append(
            ConfigPlanAction(
                section: "active_agent", target: desired, kind: .update,
                changes: ["active agent: \(current) -> \(desired)"]))
    }

    // MARK: - Agents

    private static func planAgents(
        _ entries: [AgentEntry], prune: Bool,
        into actions: inout [ConfigPlanAction], notes: inout [String]
    ) {
        let existing = AgentManager.shared.agents.filter { !$0.isBuiltIn }
        var matchedIds = Set<UUID>()
        var unchanged = 0

        for entry in entries {
            let key = entry.name.lowercased()
            if let agent = existing.first(where: { $0.name.lowercased() == key }) {
                matchedIds.insert(agent.id)
                var changes: [String] = []
                var risks: [String] = []
                diff("description", desired: entry.description, current: agent.description, into: &changes)
                diff(
                    "system_prompt", desired: entry.systemPrompt,
                    current: agent.systemPrompt, into: &changes)
                diff(
                    "model", desired: entry.model,
                    current: agent.defaultModel.map { ConfigField.value($0) } ?? .null, into: &changes)
                diff(
                    "temperature", desired: entry.temperature,
                    current: agent.temperature.map { ConfigField.value(Double($0)) } ?? .null,
                    into: &changes)
                diff(
                    "max_tokens", desired: entry.maxTokens,
                    current: agent.maxTokens.map { ConfigField.value($0) } ?? .null, into: &changes)
                if let caps = entry.capabilities {
                    diffCapabilities(caps, agent: agent, into: &changes, risks: &risks)
                }
                if changes.isEmpty {
                    unchanged += 1
                } else {
                    actions.append(
                        ConfigPlanAction(
                            section: "agents", target: entry.name, kind: .update,
                            changes: changes, risks: risks))
                }
            } else {
                var changes: [String] = ["create custom agent `\(entry.name)`"]
                var risks: [String] = []
                if let model = entry.model.valueOrNil { changes.append("model: \(model)") }
                if let caps = entry.capabilities {
                    if caps.computerUseEnabled == true { risks.append(ConfigRisk.computerUse(entry.name)) }
                    if caps.browserUseEnabled == true { risks.append(ConfigRisk.browserUse(entry.name)) }
                    if caps.relayEnabled == true { risks.append(ConfigRisk.relayEnabled(entry.name)) }
                }
                actions.append(
                    ConfigPlanAction(
                        section: "agents", target: entry.name, kind: .create,
                        changes: changes, risks: risks))
            }
        }

        if prune {
            for agent in existing where !matchedIds.contains(agent.id) {
                actions.append(
                    ConfigPlanAction(
                        section: "agents", target: agent.name, kind: .delete,
                        changes: ["delete custom agent `\(agent.name)`"],
                        risks: [ConfigRisk.deleteAgent(agent.name)]))
            }
        }
        if unchanged > 0 {
            notes.append("\(unchanged) agent(s) already match the document.")
        }
    }

    private static func diffCapabilities(
        _ caps: AgentCapabilitiesEntry, agent: Agent,
        into changes: inout [String], risks: inout [String]
    ) {
        diff("tools_enabled", desired: caps.toolsEnabled, current: agent.toolsEnabled, into: &changes)
        diff("memory_enabled", desired: caps.memoryEnabled, current: agent.memoryEnabled, into: &changes)
        diff(
            "search_memory_enabled", desired: caps.searchMemoryEnabled,
            current: agent.settings.searchMemoryEnabled, into: &changes)
        diff(
            "web_search_enabled", desired: caps.webSearchEnabled,
            current: agent.settings.webSearchEnabled, into: &changes)
        diff(
            "knowledge_enabled", desired: caps.knowledgeEnabled,
            current: agent.settings.knowledgeEnabled, into: &changes)
        if let ids = caps.knowledgeCollectionIds {
            let desired = ids.compactMap(UUID.init(uuidString:))
            if desired != agent.settings.knowledgeCollectionIds {
                changes.append("knowledge_collection_ids: \(desired.count) collection(s)")
            }
        }
        diff("db_enabled", desired: caps.dbEnabled, current: agent.settings.dbEnabled, into: &changes)
        diff(
            "self_scheduling_enabled", desired: caps.selfSchedulingEnabled,
            current: agent.settings.selfSchedulingEnabled, into: &changes)
        diff(
            "computer_use_enabled", desired: caps.computerUseEnabled,
            current: agent.settings.computerUseEnabled, into: &changes)
        diff(
            "browser_use_enabled", desired: caps.browserUseEnabled,
            current: agent.settings.browserUseEnabled, into: &changes)
        diff(
            "speak_enabled", desired: caps.speakEnabled,
            current: agent.settings.speakEnabled, into: &changes)
        diff(
            "render_chart_enabled", desired: caps.renderChartEnabled,
            current: agent.settings.renderChartEnabled, into: &changes)
        let currentRelay = RelayConfigurationStore.load().isEnabled(for: agent.id)
        diff("relay_enabled", desired: caps.relayEnabled, current: currentRelay, into: &changes)
        if caps.computerUseEnabled == true && !agent.settings.computerUseEnabled {
            risks.append(ConfigRisk.computerUse(agent.name))
        }
        if caps.browserUseEnabled == true && !agent.settings.browserUseEnabled {
            risks.append(ConfigRisk.browserUse(agent.name))
        }
        if caps.relayEnabled == true && !currentRelay {
            risks.append(ConfigRisk.relayEnabled(agent.name))
        }
    }

    // MARK: - Tools

    private static func planTools(
        _ desired: ToolsSection, into actions: inout [ConfigPlanAction], notes: inout [String]
    ) {
        let registry = ToolRegistry.shared
        var changes: [String] = []
        var risks: [String] = []
        for (tool, enabled) in (desired.enabled ?? [:]).sorted(by: { $0.key < $1.key }) {
            if !registry.isRegistered(tool) {
                notes.append("tools.enabled[\(tool)]: no such tool is currently registered — skipped.")
                continue
            }
            if registry.isGlobalEnabled(tool) != enabled {
                changes.append("\(tool): \(enabled ? "enable" : "disable")")
            }
        }
        for (tool, raw) in (desired.policies ?? [:]).sorted(by: { $0.key < $1.key }) {
            guard let policy = ToolPermissionPolicy(rawValue: raw.lowercased()) else { continue }
            if !registry.isRegistered(tool) {
                notes.append("tools.policies[\(tool)]: no such tool is currently registered — skipped.")
                continue
            }
            let current = registry.configuredPolicy(for: tool) ?? .ask
            if current != policy {
                changes.append("\(tool): policy \(current.rawValue) -> \(policy.rawValue)")
                if policy == .auto { risks.append(ConfigRisk.autoPolicy(tool)) }
            }
        }
        guard !changes.isEmpty else { return }
        actions.append(
            ConfigPlanAction(
                section: "tools", target: "tools", kind: .update, changes: changes, risks: risks))
    }

    // MARK: - App behavior (Wave 3b)

    private static func planDelegation(
        _ desired: DelegationSection, current: DelegationSection?,
        into actions: inout [ConfigPlanAction]
    ) {
        let current = current ?? DelegationSection()
        var changes: [String] = []
        var risks: [String] = []
        diff(
            "local_text_enabled", desired: desired.localTextEnabled,
            current: current.localTextEnabled, into: &changes)
        diff("image_enabled", desired: desired.imageEnabled, current: current.imageEnabled, into: &changes)
        diff("video_enabled", desired: desired.videoEnabled, current: current.videoEnabled, into: &changes)
        diff(
            "applescript_enabled", desired: desired.applescriptEnabled,
            current: current.applescriptEnabled, into: &changes)
        diff(
            "applescript_execution_mode", desired: desired.applescriptExecutionMode?.lowercased(),
            current: current.applescriptExecutionMode, into: &changes)
        diffList(
            "spawnable_agents", desired: desired.spawnableAgents,
            current: current.spawnableAgents, into: &changes)
        diffList(
            "spawnable_models", desired: desired.spawnableModels,
            current: current.spawnableModels, into: &changes)
        diff(
            "spawn_tool_access", desired: desired.spawnToolAccess?.lowercased(),
            current: current.spawnToolAccess, into: &changes)
        let normalizedDefaults = desired.permissionDefaults.map { map in
            Dictionary(
                map.map { ($0.key.lowercased(), $0.value.lowercased()) },
                uniquingKeysWith: { first, _ in first })
        }
        diffMap(
            "permission_defaults", desired: normalizedDefaults,
            current: current.permissionDefaults, defaultValue: "ask", into: &changes)
        diff(
            "budget_max_tokens", desired: desired.budgetMaxTokens,
            current: current.budgetMaxTokens, into: &changes)
        diff(
            "budget_max_turns", desired: desired.budgetMaxTurns,
            current: current.budgetMaxTurns, into: &changes)
        diff(
            "budget_max_tool_calls", desired: desired.budgetMaxToolCalls,
            current: current.budgetMaxToolCalls, into: &changes)
        diff(
            "budget_max_seconds", desired: desired.budgetMaxSeconds,
            current: current.budgetMaxSeconds, into: &changes)
        diff(
            "budget_max_parallel_spawns", desired: desired.budgetMaxParallelSpawns,
            current: current.budgetMaxParallelSpawns, into: &changes)
        diff(
            "ram_safety_preflight", desired: desired.ramSafetyPreflight,
            current: current.ramSafetyPreflight, into: &changes)
        diff(
            "coexistence_enabled", desired: desired.coexistenceEnabled,
            current: current.coexistenceEnabled, into: &changes)
        guard !changes.isEmpty else { return }

        for (kind, raw) in normalizedDefaults ?? [:]
        where raw == SubagentPermissionPolicy.alwaysAllow.rawValue
            && current.permissionDefaults?[kind] != raw
        {
            risks.append(ConfigRisk.alwaysAllowSubagent(kind))
        }
        if desired.applescriptExecutionMode?.lowercased() == "auto_run_with_warning"
            && current.applescriptExecutionMode != "auto_run_with_warning"
        {
            risks.append(ConfigRisk.applescriptAutoRun)
        }
        if desired.ramSafetyPreflight == false && current.ramSafetyPreflight != false {
            risks.append(ConfigRisk.ramPreflightDisabled)
        }
        actions.append(
            ConfigPlanAction(
                section: "delegation", target: "delegation", kind: .update,
                changes: changes, risks: risks.sorted()))
    }

    // MARK: - MCP servers

    // MARK: - Commands / Knowledge / Channels (Wave 3c)

    private static func planCommands(
        _ entries: [CommandEntry], prune: Bool, into actions: inout [ConfigPlanAction]
    ) {
        let existing = ConfigExporter.manageableCommands()
        var matched = Set<UUID>()

        for entry in entries {
            let key = entry.name.lowercased()
            if let command = existing.first(where: { $0.name.lowercased() == key }) {
                matched.insert(command.id)
                var changes: [String] = []
                diff(
                    "description", desired: entry.description,
                    current: command.description, into: &changes)
                diff("icon", desired: entry.icon, current: command.icon, into: &changes)
                diff(
                    "template", desired: entry.template,
                    current: command.template ?? "", into: &changes)
                if !changes.isEmpty {
                    actions.append(
                        ConfigPlanAction(
                            section: "commands", target: entry.name, kind: .update,
                            changes: changes))
                }
            } else {
                actions.append(
                    ConfigPlanAction(
                        section: "commands", target: entry.name, kind: .create,
                        changes: ["add template command /\(entry.name)"]))
            }
        }

        if prune {
            for command in existing where !matched.contains(command.id) {
                actions.append(
                    ConfigPlanAction(
                        section: "commands", target: command.name, kind: .delete,
                        changes: ["delete slash command /\(command.name)"],
                        risks: [ConfigRisk.deleteCommand(command.name)]))
            }
        }
    }

    private static func planKnowledgeCollections(
        _ entries: [KnowledgeCollectionEntry], prune: Bool,
        into actions: inout [ConfigPlanAction]
    ) {
        let existing = KnowledgeCollectionStore.loadAll()
        var matched = Set<UUID>()

        for entry in entries {
            let key = entry.name.lowercased()
            if let collection = existing.first(where: { $0.name.lowercased() == key }) {
                matched.insert(collection.id)
                var changes: [String] = []
                diff("summary", desired: entry.summary, current: collection.summary, into: &changes)
                diff("enabled", desired: entry.enabled, current: collection.isEnabled, into: &changes)
                diffList(
                    "include_globs", desired: entry.includeGlobs,
                    current: collection.includeGlobs, into: &changes)
                diffList(
                    "exclude_globs", desired: entry.excludeGlobs,
                    current: collection.excludeGlobs, into: &changes)
                if !changes.isEmpty {
                    actions.append(
                        ConfigPlanAction(
                            section: "knowledge_collections", target: entry.name, kind: .update,
                            changes: changes + ["re-index after update"]))
                }
            } else {
                actions.append(
                    ConfigPlanAction(
                        section: "knowledge_collections", target: entry.name, kind: .create,
                        changes: ["register collection at \(entry.folderPath ?? "?") and index it"],
                        longRunning: true))
            }
        }

        if prune {
            for collection in existing where !matched.contains(collection.id) {
                actions.append(
                    ConfigPlanAction(
                        section: "knowledge_collections", target: collection.name, kind: .delete,
                        changes: ["deregister collection and delete its search index"],
                        risks: [ConfigRisk.deleteKnowledgeCollection(collection.name)]))
            }
        }
    }

    private static func planChannels(
        _ desired: ChannelsSection, current: ChannelsSection?,
        into actions: inout [ConfigPlanAction]
    ) {
        let current = current ?? ChannelsSection()

        if let v = desired.writeEnabled, v != current.writeEnabled {
            var risks: [String] = []
            if v { risks.append(ConfigRisk.channelWritesGlobal) }
            actions.append(
                ConfigPlanAction(
                    section: "channels", target: "channels", kind: .update,
                    changes: ["write_enabled: \(display(current.writeEnabled)) -> \(v)"],
                    risks: risks))
        }

        for platform in ConfigChannelPlatform.allCases {
            guard let section = platform.section(in: desired) else { continue }
            let currentSection = platform.section(in: current) ?? ChannelPlatformSection()
            var changes: [String] = []
            var risks: [String] = []
            diff(
                "write_enabled", desired: section.writeEnabled,
                current: currentSection.writeEnabled, into: &changes)
            if section.writeEnabled == true && currentSection.writeEnabled != true {
                risks.append(ConfigRisk.channelWrites(platform.rawValue))
            }
            diff(
                "default_read_limit", desired: section.defaultReadLimit,
                current: currentSection.defaultReadLimit, into: &changes)
            diffList(
                "space_allowlist", desired: section.spaceAllowlist,
                current: currentSection.spaceAllowlist, into: &changes)
            diffList(
                "read_allowlist", desired: section.readAllowlist,
                current: currentSection.readAllowlist, into: &changes)
            diffList(
                "write_allowlist", desired: section.writeAllowlist,
                current: currentSection.writeAllowlist, into: &changes)
            diffList(
                "sender_allowlist", desired: section.senderAllowlist,
                current: currentSection.senderAllowlist, into: &changes)
            diff(
                "inbound_enabled", desired: section.inboundEnabled,
                current: currentSection.inboundEnabled, into: &changes)
            let desiredAgent: ConfigField<String> =
                section.inboundAgent.valueOrNil.map { .value($0.lowercased()) }
                ?? section.inboundAgent
            let currentAgent: ConfigField<String> =
                currentSection.inboundAgent.valueOrNil.map { .value($0.lowercased()) }
                ?? currentSection.inboundAgent
            diff("inbound_agent", desired: desiredAgent, current: currentAgent, into: &changes)
            diff(
                "require_mention", desired: section.requireMention,
                current: currentSection.requireMention, into: &changes)
            diff(
                "continue_threads", desired: section.continueThreads,
                current: currentSection.continueThreads, into: &changes)
            diff(
                "auto_reply_enabled", desired: section.autoReplyEnabled,
                current: currentSection.autoReplyEnabled, into: &changes)
            if section.autoReplyEnabled == true && currentSection.autoReplyEnabled != true {
                risks.append(ConfigRisk.channelAutoReply(platform.rawValue))
            }
            if let raw = section.botTokenRef, case .success(let ref) = ConfigSecretRef.parse(raw) {
                changes.append("bot_token: store from \(ref.display)")
            }
            if let raw = section.appTokenRef, case .success(let ref) = ConfigSecretRef.parse(raw) {
                changes.append("app_token: store from \(ref.display)")
            }
            guard !changes.isEmpty else { continue }
            actions.append(
                ConfigPlanAction(
                    section: "channels", target: platform.rawValue, kind: .update,
                    changes: changes, risks: risks))
        }
    }

    private static func planMCPServers(
        _ entries: [MCPServerEntry], prune: Bool, into actions: inout [ConfigPlanAction]
    ) {
        let existing = ConfigExporter.manageableMCPProviders()
        var matched = Set<UUID>()

        for entry in entries {
            let key = entry.name.lowercased()
            if let provider = existing.first(where: { $0.name.lowercased() == key }) {
                matched.insert(provider.id)
                var changes: [String] = []
                var risks: [String] = []
                switch provider.transport {
                case .http:
                    if let url = entry.url, url != provider.url {
                        changes.append("url: \(provider.url) -> \(url)")
                        risks.append(ConfigRisk.mcpRetarget(entry.name, from: provider.url, to: url))
                    }
                    if let auth = entry.auth,
                        let desired = ConfigMCPAuth.auth(forKey: auth),
                        desired != provider.authType
                    {
                        changes.append(
                            "auth: \(ConfigMCPAuth.key(for: provider.authType)) -> "
                                + ConfigMCPAuth.key(for: desired))
                    }
                case .stdio:
                    if let command = entry.command, command != provider.command {
                        changes.append("command: \(provider.command) -> \(command)")
                        risks.append(ConfigRisk.stdioCommand(entry.name, command))
                    }
                    if let args = entry.args, args != provider.args {
                        changes.append("args: \(display(provider.args)) -> \(display(args))")
                        risks.append(
                            ConfigRisk.stdioCommand(
                                entry.name,
                                "\(entry.command ?? provider.command) \(args.joined(separator: " "))"))
                    }
                    diffMap("env", desired: entry.env, current: provider.env, into: &changes)
                    diff(
                        "working_directory", desired: entry.workingDirectory,
                        current: provider.workingDirectory, into: &changes)
                    if let raw = entry.executionHost,
                        let desired = MCPProviderExecutionHost(rawValue: raw.lowercased()),
                        desired != provider.executionHost
                    {
                        changes.append(
                            "execution_host: \(provider.executionHost.rawValue) -> \(desired.rawValue)")
                        if desired == .host {
                            risks.append(ConfigRisk.stdioOnHost(entry.name))
                        }
                    }
                }
                diff("enabled", desired: entry.enabled, current: provider.enabled, into: &changes)
                if provider.transport == .http, let raw = entry.tokenRef,
                    case .success(let ref) = ConfigSecretRef.parse(raw)
                {
                    changes.append("token: store from \(ref.display)")
                }
                if provider.transport == .stdio, let refs = entry.secretEnvRefs {
                    for (envKey, raw) in refs.sorted(by: { $0.key < $1.key }) {
                        guard case .success(let ref) = ConfigSecretRef.parse(raw) else { continue }
                        changes.append("secret env \(envKey): store from \(ref.display)")
                    }
                }
                if !changes.isEmpty {
                    actions.append(
                        ConfigPlanAction(
                            section: "mcp_servers", target: entry.name, kind: .update,
                            changes: changes, risks: risks))
                }
            } else if entry.transport?.lowercased() == "stdio" {
                // Validation guarantees `command` for new stdio servers.
                let command = entry.command ?? ""
                let commandLine =
                    ([command] + (entry.args ?? [])).joined(separator: " ")
                var changes = ["add stdio MCP server running: \(commandLine)"]
                var risks = [ConfigRisk.stdioCommand(entry.name, commandLine)]
                let host =
                    entry.executionHost.flatMap {
                        MCPProviderExecutionHost(rawValue: $0.lowercased())
                    } ?? .sandbox
                if host == .host {
                    changes.append("execution_host: host")
                    risks.append(ConfigRisk.stdioOnHost(entry.name))
                }
                if let refs = entry.secretEnvRefs {
                    for (envKey, raw) in refs.sorted(by: { $0.key < $1.key }) {
                        guard case .success(let ref) = ConfigSecretRef.parse(raw) else { continue }
                        changes.append("secret env \(envKey): store from \(ref.display)")
                    }
                }
                actions.append(
                    ConfigPlanAction(
                        section: "mcp_servers", target: entry.name, kind: .create,
                        changes: changes, risks: risks))
            } else {
                // Validation guarantees `url` for new HTTP servers.
                let url = entry.url ?? ""
                var changes = ["add HTTP MCP server at \(url)"]
                let risks = [ConfigRisk.mcpEndpoint(entry.name, url)]
                let auth = entry.auth.flatMap(ConfigMCPAuth.auth(forKey:)) ?? MCPProviderAuthType.none
                if let raw = entry.tokenRef, case .success(let ref) = ConfigSecretRef.parse(raw) {
                    changes.append("auth: bearer — token stored from \(ref.display)")
                } else if auth != .none {
                    changes.append(
                        "auth: \(ConfigMCPAuth.key(for: auth)) — finish sign-in in "
                            + "Settings → Tools → Remote (secrets never travel through the document)")
                }
                actions.append(
                    ConfigPlanAction(
                        section: "mcp_servers", target: entry.name, kind: .create,
                        changes: changes, risks: risks))
            }
        }

        if prune {
            for provider in existing where !matched.contains(provider.id) {
                let location =
                    provider.transport == .stdio ? provider.command : provider.url
                actions.append(
                    ConfigPlanAction(
                        section: "mcp_servers", target: provider.name, kind: .delete,
                        changes: ["remove MCP server \(location)"],
                        risks: [ConfigRisk.deleteMCPServer(provider.name)]))
            }
        }
    }

    // MARK: - Models / Plugins

    private static func planModels(
        _ desired: [String], prune: Bool,
        into actions: inout [ConfigPlanAction], notes: inout [String]
    ) {
        let installed = Set(
            ModelManager.shared.availableModels.filter { $0.isDownloaded }.map { $0.id })
        for id in desired where !installed.contains(id) {
            actions.append(
                ConfigPlanAction(
                    section: "models", target: id, kind: .create,
                    changes: ["download from Hugging Face (MLX compatibility checked during apply)"],
                    longRunning: true))
        }
        if prune {
            let wanted = Set(desired)
            for id in installed.subtracting(wanted).sorted() {
                actions.append(
                    ConfigPlanAction(
                        section: "models", target: id, kind: .delete,
                        changes: ["delete model files from disk"],
                        risks: [ConfigRisk.deleteModel(id)]))
            }
        }
        let already = desired.filter { installed.contains($0) }.count
        if already > 0 { notes.append("\(already) model(s) already installed.") }
    }

    private static func planPlugins(
        _ desired: [String], prune: Bool, into actions: inout [ConfigPlanAction]
    ) {
        let installed = Set(PluginManager.shared.plugins.map { $0.plugin.id })
        for id in desired where !installed.contains(id) {
            actions.append(
                ConfigPlanAction(
                    section: "plugins", target: id, kind: .create,
                    changes: ["install from the plugin registry"]))
        }
        if prune {
            let wanted = Set(desired)
            for id in installed.subtracting(wanted).sorted() {
                actions.append(
                    ConfigPlanAction(
                        section: "plugins", target: id, kind: .delete,
                        changes: ["uninstall plugin"],
                        risks: [ConfigRisk.uninstallPlugin(id)]))
            }
        }
    }

    // MARK: - Cloud providers

    private static func planProviders(
        _ entries: [ProviderEntry], prune: Bool,
        into actions: inout [ConfigPlanAction], notes: inout [String]
    ) {
        // Ephemeral providers are memory-only runtime state: never matched,
        // never pruned by a declarative document.
        let existing = ConfigProviderPresets.manageableProviders()
        var matched = Set<UUID>()

        for entry in entries {
            let key = entry.name.lowercased()
            if let provider = existing.first(where: { $0.name.lowercased() == key }) {
                matched.insert(provider.id)
                var changes: [String] = []
                diff("enabled", desired: entry.enabled, current: provider.enabled, into: &changes)
                diff(
                    "auto_connect", desired: entry.autoConnect,
                    current: provider.autoConnect, into: &changes)
                diff(
                    "timeout_seconds", desired: entry.timeoutSeconds,
                    current: provider.timeout, into: &changes)
                diff(
                    "disable_timeout", desired: entry.disableTimeout,
                    current: provider.disableTimeout, into: &changes)
                diffList(
                    "manual_model_ids", desired: entry.manualModelIds,
                    current: provider.manualModelIds, into: &changes)
                if let raw = entry.provider,
                    raw.lowercased() != ConfigProviderPresets.exportId(for: provider)
                {
                    notes.append(
                        "providers[\(entry.name)]: `provider` is immutable after creation — remove "
                            + "and re-add to change the vendor. Ignored.")
                }
                if !changes.isEmpty {
                    actions.append(
                        ConfigPlanAction(
                            section: "providers", target: entry.name, kind: .update, changes: changes))
                }
                // A secret reference stores the key non-interactively; like
                // `set_api_key` it always plans (rotation intent), but never
                // needs user input.
                if let raw = entry.apiKeyRef, case .success(let ref) = ConfigSecretRef.parse(raw) {
                    actions.append(
                        ConfigPlanAction(
                            section: "providers", target: entry.name, kind: .update,
                            changes: [
                                "credentials: store API key from \(ref.display) "
                                    + "(resolved at apply; never in the document)"
                            ]))
                } else
                // An explicit `set_api_key: true` always plans a credential
                // prompt — the user is asking to set/rotate the key even when
                // working credentials (e.g. OAuth) already exist. Without it,
                // "set up xAI with an API key" on an OAuth-connected provider
                // planned an empty diff and the sheet never opened.
                if entry.setApiKey == true {
                    actions.append(
                        ConfigPlanAction(
                            section: "providers", target: entry.name, kind: .needsUserInput,
                            changes: [
                                "set/rotate credentials — opens the secure credential sheet "
                                    + "during apply (keys never travel through the document)"
                            ]))
                } else {
                    // A registered provider with no stored secret is not
                    // "already configured" — apply will open the credential
                    // sheet, so the plan must say so instead of an empty diff.
                    switch ConfigApplier.credentialAvailability(for: provider) {
                    case .absent, .corrupt:
                        actions.append(
                            ConfigPlanAction(
                                section: "providers", target: entry.name, kind: .needsUserInput,
                                changes: [
                                    "restore missing credentials — opens the secure credential "
                                        + "sheet during apply (keys never travel through the "
                                        + "document)"
                                ]))
                    case .present, .unavailable:
                        break
                    }
                }
            } else if let raw = entry.apiKeyRef,
                case .success(let ref) = ConfigSecretRef.parse(raw)
            {
                actions.append(
                    ConfigPlanAction(
                        section: "providers", target: entry.name, kind: .create,
                        changes: [
                            "add \(entry.provider ?? "?") provider with API key from "
                                + "\(ref.display) (resolved at apply; never in the document)"
                        ]))
            } else {
                actions.append(
                    ConfigPlanAction(
                        section: "providers", target: entry.name, kind: .needsUserInput,
                        changes: [
                            "add \(entry.provider ?? "?") provider — opens the secure credential "
                                + "sheet during apply (keys never travel through the document)"
                        ]))
            }
        }

        if prune {
            for provider in existing where !matched.contains(provider.id) {
                actions.append(
                    ConfigPlanAction(
                        section: "providers", target: provider.name, kind: .delete,
                        changes: ["remove provider and its stored credentials"],
                        risks: [ConfigRisk.deleteProvider(provider.name)]))
            }
        }
    }

    // MARK: - Search providers

    private static func planSearchProviders(
        _ desired: SearchProvidersSection, prune: Bool, into actions: inout [ConfigPlanAction]
    ) {
        let manager = SearchProviderManager.shared
        let ranked = manager.rankedProviders
        let configuredIds = Set(ranked.map { $0.definition.id })

        for entry in desired.providers ?? [] {
            if let existing = ranked.first(where: { $0.definition.id == entry.id }) {
                var changes: [String] = []
                diff("enabled", desired: entry.enabled, current: existing.provider.enabled, into: &changes)
                if !changes.isEmpty {
                    actions.append(
                        ConfigPlanAction(
                            section: "search_providers", target: entry.id, kind: .update,
                            changes: changes))
                }
            } else {
                var changes = ["add search provider"]
                if let def = manager.definition(id: entry.id), !def.isKeyless {
                    changes.append("needs an API key — paste it in Settings → Search after apply")
                }
                actions.append(
                    ConfigPlanAction(
                        section: "search_providers", target: entry.id, kind: .create, changes: changes))
            }
        }

        if prune, let listed = desired.providers {
            let wanted = Set(listed.map { $0.id })
            for id in configuredIds.subtracting(wanted).sorted() {
                actions.append(
                    ConfigPlanAction(
                        section: "search_providers", target: id, kind: .delete,
                        changes: ["remove search provider"],
                        risks: [ConfigRisk.deleteSearchProvider(id)]))
            }
        }

        if let ranking = desired.ranking {
            let currentRanking = ranked.map { $0.definition.id }
            if ranking != Array(currentRanking.prefix(ranking.count)) {
                actions.append(
                    ConfigPlanAction(
                        section: "search_providers", target: "ranking", kind: .update,
                        changes: ["ranking: \(currentRanking.joined(separator: " > ")) -> "
                            + "\(ranking.joined(separator: " > ")) (unlisted keep relative order)"]))
            }
        }
    }

    // MARK: - Schedules

    private static func planSchedules(
        _ entries: [ScheduleEntry], document: OsaurusConfigDocument, prune: Bool,
        into actions: inout [ConfigPlanAction]
    ) {
        let existing = ScheduleManager.shared.schedules
        var matched = Set<UUID>()

        for entry in entries {
            let key = entry.name.lowercased()
            if let schedule = existing.first(where: { $0.name.lowercased() == key }) {
                matched.insert(schedule.id)
                var changes: [String] = []
                if let agent = entry.agent {
                    let currentAgent = AgentManager.shared.agents
                        .first { $0.id == schedule.agentId }?.name ?? "(unknown)"
                    if agent.lowercased() != currentAgent.lowercased() {
                        changes.append("agent: \(currentAgent) -> \(agent)")
                    }
                }
                diff(
                    "instructions", desired: entry.instructions,
                    current: schedule.instructions, into: &changes)
                if let frequency = entry.frequency {
                    // Canonicalize BOTH sides through parse -> components so
                    // lenient input ("Daily", "Monday", hourly `0`) never
                    // shows as a change against the exported normal form.
                    // Validation already rejected unparseable triples.
                    let currentParts = ConfigScheduleFrequency.components(of: schedule.frequency)
                    let desiredParts: (frequency: String, value: String?, timeOfDay: String?)
                    switch ConfigScheduleFrequency.parse(
                        frequency: frequency,
                        value: entry.frequencyValue,
                        timeOfDay: entry.frequencyTimeOfDay
                    ) {
                    case .success(let parsed):
                        desiredParts = ConfigScheduleFrequency.components(of: parsed)
                    case .failure:
                        desiredParts = (frequency, entry.frequencyValue, entry.frequencyTimeOfDay)
                    }
                    if desiredParts != currentParts {
                        changes.append(
                            "frequency: \(describeTriple(currentParts)) -> "
                                + describeTriple(desiredParts))
                    }
                }
                diff("enabled", desired: entry.enabled, current: schedule.isEnabled, into: &changes)
                if !changes.isEmpty {
                    actions.append(
                        ConfigPlanAction(
                            section: "schedules", target: entry.name, kind: .update, changes: changes))
                }
            } else {
                var changes = ["create schedule for agent `\(entry.agent ?? "?")`"]
                if let frequency = entry.frequency {
                    changes.append(
                        "frequency: "
                            + describeTriple((frequency, entry.frequencyValue, entry.frequencyTimeOfDay)))
                }
                actions.append(
                    ConfigPlanAction(
                        section: "schedules", target: entry.name, kind: .create, changes: changes))
            }
        }

        if prune {
            for schedule in existing where !matched.contains(schedule.id) {
                actions.append(
                    ConfigPlanAction(
                        section: "schedules", target: schedule.name, kind: .delete,
                        changes: ["delete schedule"],
                        risks: [ConfigRisk.deleteSchedule(schedule.name)]))
            }
        }
    }

    private static func describeTriple(
        _ triple: (frequency: String, value: String?, timeOfDay: String?)
    ) -> String {
        var parts = [triple.frequency]
        if let v = triple.value { parts.append(v) }
        if let t = triple.timeOfDay { parts.append("at \(t)") }
        return parts.joined(separator: " ")
    }

    // MARK: - Watchers

    private static func planWatchers(
        _ entries: [WatcherEntry], document: OsaurusConfigDocument, prune: Bool,
        into actions: inout [ConfigPlanAction]
    ) {
        let existing = WatcherManager.shared.watchers
        var matched = Set<UUID>()

        for entry in entries {
            let key = entry.name.lowercased()
            if let watcher = existing.first(where: { $0.name.lowercased() == key }) {
                matched.insert(watcher.id)
                var changes: [String] = []
                if let agent = entry.agent {
                    let currentAgent = AgentManager.shared.agents
                        .first { $0.id == watcher.agentId }?.name ?? "(unknown)"
                    if agent.lowercased() != currentAgent.lowercased() {
                        changes.append("agent: \(currentAgent) -> \(agent)")
                    }
                }
                diff(
                    "instructions", desired: entry.instructions,
                    current: watcher.instructions, into: &changes)
                if let raw = entry.path {
                    let expanded = (raw as NSString).expandingTildeInPath
                    diff("path", desired: expanded, current: watcher.watchPath, into: &changes)
                }
                diff("recursive", desired: entry.recursive, current: watcher.recursive, into: &changes)
                diff(
                    "responsiveness", desired: entry.responsiveness?.lowercased(),
                    current: watcher.responsiveness.rawValue, into: &changes)
                diff("enabled", desired: entry.enabled, current: watcher.isEnabled, into: &changes)
                if !changes.isEmpty {
                    actions.append(
                        ConfigPlanAction(
                            section: "watchers", target: entry.name, kind: .update, changes: changes))
                }
            } else {
                let path = (entry.path.map { ($0 as NSString).expandingTildeInPath }) ?? "?"
                actions.append(
                    ConfigPlanAction(
                        section: "watchers", target: entry.name, kind: .create,
                        changes: ["watch \(path) with agent `\(entry.agent ?? "?")`"]))
            }
        }

        if prune {
            for watcher in existing where !matched.contains(watcher.id) {
                actions.append(
                    ConfigPlanAction(
                        section: "watchers", target: watcher.name, kind: .delete,
                        changes: ["delete watcher"],
                        risks: [ConfigRisk.deleteWatcher(watcher.name)]))
            }
        }
    }
}
