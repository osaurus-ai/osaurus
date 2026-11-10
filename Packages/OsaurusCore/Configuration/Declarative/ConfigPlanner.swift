//
//  ConfigPlanner.swift
//  osaurus
//
//  Diffs an `OsaurusConfigDocument` against current Osaurus state and
//  produces a `ConfigPlan`. Merge-by-default: only sections present in
//  the document are considered, and within entity sections (agents,
//  mcp_servers, models, plugins, providers, events) only
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
    /// A per-call approval tool (send / delete) cannot be made silent: the
    /// registry forces `ask` at execution, so the stored `auto` is inert.
    static func autoPolicyIgnoredPerCall(_ tool: String) -> String {
        "Sets tool `\(tool)` to auto, but it always asks for approval on every call (it sends or deletes as the user) — the setting is stored and has no effect."
    }
    /// Argument-aware per-call tools (`mail_compose` / `mail_reply`): `auto`
    /// covers drafts, never the `send: true` calls.
    static func autoPolicySendsStillAsk(_ tool: String) -> String {
        "Sets tool `\(tool)` to auto — drafts will run without asking; calls that send as the user still show an approval card every time."
    }
    /// The sandbox adapters run commands and write files in the VM; only
    /// the workspace tools are meant to reach them.
    static func sandboxAdapterEnabled(_ tool: String) -> String {
        "Enables `\(tool)` directly — it runs commands or writes files in the sandbox without going through the workspace tools."
    }
    static func computerUse(_ agent: String) -> String {
        "Gives agent `\(agent)` screen control (computer use)."
    }
    static func browserUse(_ agent: String) -> String {
        "Gives agent `\(agent)` browser automation."
    }
    /// Apple apps whose tools can act on the user's behalf outside Osaurus
    /// (send mail / iMessages, run arbitrary Shortcuts). Reads and the
    /// organiser apps stay risk-free; the model still gets a per-call
    /// approval prompt for each send.
    static let riskyAppleApps: Set<AppleApp> = [.mail, .messages, .shortcuts]
    static func appleApp(_ agent: String, _ app: AppleApp) -> String {
        switch app {
        case .mail: return "Lets agent `\(agent)` read and send email as the user (Mail)."
        case .messages: return "Lets agent `\(agent)` read and send iMessages/SMS as the user (Messages)."
        case .shortcuts: return "Lets agent `\(agent)` run the user's Shortcuts (arbitrary automations)."
        default: return "Gives agent `\(agent)` access to \(app.displayName)."
        }
    }
    /// Risk lines for the Apple apps newly turned on (present in `desired`,
    /// absent from `current`) that are in `riskyAppleApps`.
    static func appleAppRisks(_ agent: String, current: Set<AppleApp>, desired: Set<AppleApp>) -> [String] {
        AppleApp.sorted(desired.subtracting(current).intersection(riskyAppleApps)).map { appleApp(agent, $0) }
    }
    static func relayEnabled(_ agent: String) -> String {
        "Turns on remote access for agent `\(agent)` (reachable from outside this Mac)."
    }
    static func alwaysAllowSubagent(_ kind: String) -> String {
        "Sets subagent kind `\(kind)` to always_allow — its jobs run without asking."
    }
    static let applescriptAutoRun =
        "AppleScript automations auto-run with only a warning (no per-script confirmation)."
    /// `spawnable_agents` REPLACES the pool. A document that lists none
    /// while the pool has members (or custom agents exist) takes
    /// `spawn_agent` away from the Orchestrator until an agent is added
    /// back — the silent-empty-pool failure this card must name.
    static func emptiesSpawnPool(removed: Int, customAgents: Int) -> String {
        "Empties the Orchestrator's spawn pool (`spawnable_agents` replaces the whole list; "
            + "\(removed) spawnable agent\(removed == 1 ? "" : "s") removed, \(customAgents) custom "
            + "agent\(customAgents == 1 ? "" : "s") exist) — the Orchestrator loses `spawn_agent` "
            + "and cannot delegate until an agent is listed again."
    }
    static func emptiesWorkspaceSpawnPool(removed: Int) -> String {
        "Removes every teammate agent from the Orchestrator's pool (`spawnable_workspace_agents` "
            + "replaces the whole list; \(removed) removed)."
    }
    static let ramPreflightDisabled =
        "Turns off \"Check memory before delegating\" for subagent tasks."
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
        "Matching \(platform) messages get replies without per-message confirmation."
    }
    static func channelAutonomousPosting(_ agent: String, _ platform: String) -> String {
        "Lets agent `\(agent)` post on \(platform) on its own without asking first."
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
    static func deleteEvent(_ name: String) -> String {
        "Deletes event `\(name)` (prune)."
    }
    static func unsignedWebhook(_ name: String) -> String {
        "Webhook event `\(name)` accepts any caller that knows its URL (no signature or secret check)."
    }
    static func deleteSearchProvider(_ id: String) -> String {
        "Removes search provider `\(id)` and its stored key (prune)."
    }
    static func harnessCommand(_ name: String, _ commandLine: String) -> String {
        "Harness runtime `\(name)` launches a local program for every chat of an agent on it: \(commandLine)"
    }
    static func harnessEnvironment(_ name: String) -> String {
        "Changes the environment harness runtime `\(name)` launches with."
    }
    static func deleteHarnessRuntime(_ name: String) -> String {
        "Removes harness runtime `\(name)` (prune); agents on it stop running until they get another runtime."
    }
    static func agentOnHarness(_ agent: String, _ runtime: String) -> String {
        "Agent `\(agent)` runs on harness `\(runtime)`: a local program with its own tools, outside the Osaurus sandbox."
    }
    static func claudeCodeShell(_ agent: String) -> String {
        "Lets Claude Code run shell commands for agent `\(agent)`, unconfined on this Mac."
    }
    static func claudeCodeConfigWrites(_ agent: String) -> String {
        "Lets Claude Code change Osaurus configuration for agent `\(agent)`."
    }
}

@MainActor
enum ConfigPlanner {

    /// Build the plan. Throws `ConfigPlanIssues` when the document is
    /// invalid (every issue listed at once).
    static func plan(document: OsaurusConfigDocument, prune: Bool) throws -> ConfigPlan {
        let (translated, legacyNotes) = document.translatingLegacyEvents()
        var issues: [String] = []
        validate(document: translated, prune: prune, into: &issues)
        if prune { validatePruneAgentReferences(document: translated, into: &issues) }
        if !issues.isEmpty { throw ConfigPlanIssues(issues: issues) }

        // Post-validation, every model reference resolves; rewrite them to
        // canonical form so the plan shows exactly what apply will store
        // (e.g. bare `claude-x` -> `anthropic/claude-x`).
        let document = normalizedModelReferences(in: translated)

        let current = ConfigExporter.export()
        var actions: [ConfigPlanAction] = []
        var notes: [String] = legacyNotes

        if let section = document.memory {
            planMemory(section, current: current.memory, into: &actions)
        }
        if let entries = document.harnessRuntimes {
            planHarnessRuntimes(entries, prune: prune, into: &actions)
        }
        if let section = document.defaultAgent {
            planDefaultAgent(section, current: current.defaultAgent, into: &actions)
        }
        if let section = document.configurator {
            planConfigurator(section, current: current.configurator, into: &actions)
        }
        if let entries = document.agents {
            planAgents(entries, prune: prune, into: &actions, notes: &notes)
        }
        if let name = document.activeAgent {
            planActiveAgent(name, current: current.activeAgent ?? "default", into: &actions)
        }
        if let section = document.modelDefaults {
            planModelDefaults(section, current: current.modelDefaults, into: &actions)
        }
        if let section = document.chat {
            planChat(section, current: current.chat, into: &actions)
        }
        if let section = document.app {
            planApp(section, current: current.app, into: &actions)
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
        let agentNames = effectiveAgentNames(document: document, prune: prune)
        if let entries = document.automations {
            ConfigEvents.plan(entries, agentNames: agentNames, prune: prune, into: &actions)
        }
        for scoped in ConfigChannelRouting.scopes(in: document) {
            guard let scope = scoped.scope else { continue }
            ConfigEvents.plan(scoped.entries, scope: scope, agentNames: agentNames, prune: prune, into: &actions)
        }
        for target in ConfigChannelPlatform.targets(in: document.channels) {
            guard target.platform.supportsPosting, let posting = target.section.posting,
                ConfigChannelAccounts.isKnown(target)
            else { continue }
            ConfigChannelPosting.plan(posting, target: target, agentNames: agentNames, prune: prune, into: &actions)
        }

        var plan = ConfigPlan(actions: actions, notes: notes)
        if !plan.isEmpty, let currentYAML = try? ConfigYAML.canonical(current) {
            plan.diffText = ConfigDiff.preview(currentYAML: currentYAML, desired: document, prune: prune)
        }
        return plan
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
    /// cascade events (it only resets the active-agent selection to
    /// Default). Refuse a document whose prune would leave a SURVIVING event
    /// pointing at a deleted agent: the user must delete or reassign it in
    /// the same document.
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

        // An event survives when `events:` is absent (merge semantics leave
        // it alone) or when it is listed (prune only deletes UNLISTED
        // entries). A listed entry that reassigns `agent` / `workflow` is
        // validated against the post-apply agent set by the regular checks.
        ConfigEvents.validatePruneAgentReferences(
            document: document, prunedNameById: prunedNameById, into: &issues)
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
        if let section = document.configurator {
            check(
                section.model,
                current: ConfiguratorConfigurationStore.load().resolvedModel,
                label: "configurator.model")
        }
        if let section = document.modelDefaults {
            let chat = ChatConfigurationStore.load()
            check(section.coreModel, current: chat.coreModelIdentifier, label: "model_defaults.core_model")
            check(
                section.compactionModel, current: chat.compactionModelIdentifier,
                label: "model_defaults.compaction_model")
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
        if var section = document.configurator {
            section.model = canonical(section.model)
            document.configurator = section
        }
        if var section = document.modelDefaults {
            section.coreModel = canonical(section.coreModel)
            section.compactionModel = canonical(section.compactionModel)
            document.modelDefaults = section
        }
        if var section = document.app, case .value(let text) = section.hotkey,
            case .success(let hotkey) = HotkeyText.parse(text)
        {
            section.hotkey = .value(HotkeyText.text(for: hotkey))
            document.app = section
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
        validateHarnessRuntimes(document: document, prune: prune, into: &issues)
        if let section = document.defaultAgent {
            checkRange(section.temperature, 0.0...2.0, "default_agent.temperature", &issues)
            checkRange(section.maxTokens, 1...10_000_000, "default_agent.max_tokens", &issues)
            checkRuntimeReference(
                section.runtime, claudeCode: section.claudeCode, label: "default_agent",
                document: document, prune: prune, into: &issues)
        }
        if let section = document.configurator {
            checkRange(section.temperature, 0.0...2.0, "configurator.temperature", &issues)
        }
        if let section = document.app, case .value(let text) = section.hotkey,
            case .failure(let error) = HotkeyText.parse(text),
            text != ConfigExporter.currentHotkeyText()
        {
            issues.append("app.hotkey: \(error.message)")
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
                do { try entry.generationSettings.valueOrNil?.validate() }
                catch { issues.append("agents[\(entry.name)].generation_settings: \(error.localizedDescription)") }
                checkRuntimeReference(
                    entry.runtime, claudeCode: entry.claudeCode, label: "agents[\(entry.name)]",
                    document: document, prune: prune, into: &issues)
                if entry.claudeCode?.allowOsaurusConfigWrites != nil {
                    issues.append(
                        "agents[\(entry.name)].claude_code.allow_osaurus_config_writes: only the "
                            + "Default agent can change Osaurus configuration.")
                }
                if let ids = entry.capabilities?.knowledgeCollectionIds {
                    for raw in ids where UUID(uuidString: raw) == nil {
                        issues.append(
                            "agents[\(entry.name)].capabilities.knowledge_collection_ids: "
                                + "`\(raw)` is not a UUID.")
                    }
                }
                if let mode = entry.tools?.mode, ToolSelectionMode(rawValue: mode) == nil {
                    issues.append(
                        "agents[\(entry.name)].tools.mode: must be `auto` or `manual` (got `\(mode)`).")
                }
                if let v = entry.sandbox?.maxCommandsPerTurn, !(1...500).contains(v) {
                    issues.append(
                        "agents[\(entry.name)].sandbox.max_commands_per_turn: must be in 1...500.")
                }
                if let names = entry.workflows {
                    for raw in names where InstalledWorkflowStore.shared.workflow(named: raw) == nil {
                        if let refusal = AgentWrapperCatalog.configRefusal(raw) {
                            issues.append("agents[\(entry.name)].workflows: \(refusal)")
                            continue
                        }
                        let installed = InstalledWorkflowStore.shared.workflows.map(\.name)
                        issues.append(
                            "agents[\(entry.name)].workflows: `\(raw)` is not an installed workflow. Installed: "
                                + (installed.isEmpty ? "none" : installed.joined(separator: ", ")) + ".")
                    }
                }
                if let apps = entry.capabilities?.appleApps {
                    for raw in apps where AppleApp.parse(raw) == nil {
                        issues.append(
                            "agents[\(entry.name)].capabilities.apple_apps: `\(raw)` is not a "
                                + "built-in Apple app. Allowed: "
                                + AppleApp.allCases.map(\.rawValue).joined(separator: ", ") + ".")
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
                    "new_chat_agent: no agent named `\(active)` exists or is created by this document.")
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
                section.budgetMaxSeconds, SubagentBudgets.elapsedBounds, "budget_max_seconds")
            checkBudget(
                section.budgetMaxParallelSpawns, SubagentBudgets.parallelSpawnBounds,
                "budget_max_parallel_spawns")
            checkBudget(
                section.budgetMaxRemoteParallelSpawns, SubagentBudgets.remoteParallelSpawnBounds,
                "budget_max_remote_parallel_spawns")
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
            // Workspace targets: the durable `<workspace_id>:<address>` key is
            // accepted by shape alone (the roster may not be loaded yet);
            // `Name@Workspace`, a bare name or a `0x…` address must resolve
            // against the live roster, and an ambiguous name lists the exact
            // forms that disambiguate.
            for key in section.spawnableWorkspaceAgents ?? [] {
                if case .failure(let message) = ConfigApplier.resolveWorkspaceAgentKey(key) {
                    issues.append("delegation.spawnable_workspace_agents: " + message)
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
            ConfigChannelAccounts.validate(channels, into: &issues)
            for target in ConfigChannelPlatform.targets(in: channels) {
                let platform = target.platform
                let section = target.section
                let label = target.path
                if !ConfigChannelAccounts.isKnown(target) {
                    issues.append(ConfigChannelAccounts.unknownAccountIssue(target))
                    continue
                }
                if let v = section.defaultReadLimit, !(1...100).contains(v) {
                    issues.append("\(label).default_read_limit: must be in 1...100.")
                }
                if let raw = section.botTokenRef {
                    if platform.supportsBotTokenRef {
                        validateSecretRef(raw, label: "\(label).bot_token_ref", into: &issues)
                    } else {
                        issues.append(
                            "\(label).bot_token_ref: \(platform.rawValue) has no bot token — "
                                + "iMessage needs none, WhatsApp links interactively, and Email uses its "
                                + "mail accounts' own sign-in.")
                    }
                }
                if let raw = section.appTokenRef {
                    if platform.supportsAppTokenRef {
                        validateSecretRef(raw, label: "\(label).app_token_ref", into: &issues)
                    } else {
                        issues.append("\(label).app_token_ref: only Slack uses an app-level token.")
                    }
                }
                if !platform.hasWriteAllowlist, section.writeAllowlist != nil {
                    issues.append(
                        "\(label).write_allowlist: \(platform.rawValue) replies in every watched mailbox "
                            + "once write_enabled is true — there is no separate write list.")
                }
                if !platform.supportsPosting, section.posting != nil {
                    issues.append(
                        "\(label).posting: \(platform.rawValue) agents only reply to mail they received — "
                            + "they cannot post on their own.")
                }
                if platform == .email {
                    validateEmailRooms(section.readAllowlist ?? [], label: label, into: &issues)
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
                    if let refs = entry.secretHeaderRefs {
                        for (header, raw) in refs.sorted(by: { $0.key < $1.key }) {
                            if header.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                issues.append(
                                    "mcp_servers[\(entry.name)].secret_header_refs: header names "
                                        + "must be non-empty.")
                                continue
                            }
                            validateSecretRef(
                                raw,
                                label: "mcp_servers[\(entry.name)].secret_header_refs[\(header)]",
                                into: &issues)
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
                    if entry.url != nil || entry.auth != nil || entry.tokenRef != nil
                        || entry.secretHeaderRefs != nil
                    {
                        issues.append(
                            "mcp_servers[\(entry.name)]: url/auth/token_ref/secret_header_refs only "
                                + "apply to transport: http.")
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
        var eventNames = Set<String>()
        if let events = document.automations {
            for entry in events where entry.source?.kind?.lowercased() == EventSourceKind.channelMessage.rawValue {
                issues.append(
                    "automations[\(entry.name)]: channel rules live under `channels.<platform>.routing` "
                        + "(`channels.connections[].routing` for n8n / custom HTTP); this one names no known "
                        + "platform or connection.")
            }
            ConfigEvents.validate(
                events.filter { $0.source?.kind?.lowercased() != EventSourceKind.channelMessage.rawValue },
                agentNames: agentNames, seen: &eventNames, into: &issues)
        }
        for scoped in ConfigChannelRouting.scopes(in: document) {
            if let issue = scoped.issue { issues.append(issue) }
            guard let scope = scoped.scope else { continue }
            ConfigEvents.validate(scoped.entries, scope: scope, agentNames: agentNames, seen: &eventNames, into: &issues)
        }
        issues += ConfigChannelRouting.autoReplyIssues(in: document, prune: prune)
        for target in ConfigChannelPlatform.targets(in: document.channels) {
            guard target.platform.supportsPosting, let posting = target.section.posting,
                ConfigChannelAccounts.isKnown(target)
            else { continue }
            ConfigChannelPosting.validate(posting, target: target, agentNames: agentNames, into: &issues)
        }
    }

    /// Email rooms are `<mail account id>/<mailbox>`; the account must be a
    /// Mail app or IMAP account added in Settings.
    private static func validateEmailRooms(_ rooms: [String], label: String, into issues: inout [String]) {
        let accounts = Set(SourceConnectionStore.shared.connections(of: [.mailApp, .imap]).map(\.id))
        for room in rooms {
            guard let route = EmailChannelConfiguration.parseRoomId(room) else {
                issues.append("\(label).read_allowlist: `\(room)` must be `<mail account id>/<mailbox>`.")
                continue
            }
            if !accounts.contains(route.connectionId) {
                issues.append(
                    "\(label).read_allowlist: `\(room)` names no mail account. Add the account in "
                        + "Settings → Channels → Email first.")
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
        var risks: [String] = []
        let stored = DefaultAgentConfigurationStore.load()
        diffRuntime(
            desired.runtime, claudeCode: desired.claudeCode,
            currentRuntime: stored.runtime, currentClaudeCode: stored.claudeCode ?? .default,
            agent: "default", into: &changes, risks: &risks)
        guard !changes.isEmpty else { return }
        actions.append(
            ConfigPlanAction(
                section: "default_agent", target: "default_agent", kind: .update,
                changes: changes, risks: risks))
    }

    private static func planConfigurator(
        _ desired: ConfiguratorSection, current: ConfiguratorSection?,
        into actions: inout [ConfigPlanAction]
    ) {
        let current = current ?? ConfiguratorSection()
        var changes: [String] = []
        diff("model", desired: desired.model, current: current.model, into: &changes)
        diff("temperature", desired: desired.temperature, current: current.temperature, into: &changes)
        diff("system_prompt", desired: desired.systemPrompt, current: current.systemPrompt, into: &changes)
        guard !changes.isEmpty else { return }
        actions.append(
            ConfigPlanAction(
                section: ConfigSectionID.configurator.rawValue, target: "configurator",
                kind: .update, changes: changes))
    }

    static func sharedToolApprovalChange(_ policy: SharedToolApprovalPolicy) -> String {
        switch policy.mode {
        case .deny:
            return "shared_tool_approval: deny (teammates' tool calls that need approval fail)"
        case .askOwner:
            return "shared_tool_approval: ask_owner (you approve teammates' tool calls; "
                + "declined after \(Int(policy.effectiveTimeout))s)"
        }
    }

    /// Plan lines and risks for an agent's `runtime` and `claude_code` keys.
    @MainActor
    private static func diffRuntime(
        _ runtime: String?, claudeCode: AgentClaudeCodeEntry?,
        currentRuntime: AgentRuntime?, currentClaudeCode: ClaudeCodeAgentConfig,
        agent: String, into changes: inout [String], risks: inout [String]
    ) {
        if let runtime {
            let currentKey = ConfigHarness.runtimeKey(for: currentRuntime)
            let desiredKey = ConfigHarness.normalizedName(runtime)
            if currentKey.map(ConfigHarness.normalizedName) != desiredKey {
                changes.append("runtime: \(currentKey ?? "(deleted runtime)") -> \(runtime)")
                if desiredKey != ConfigHarness.builtInRuntimeKey {
                    risks.append(ConfigRisk.agentOnHarness(agent, runtime))
                }
            }
        }
        if let claudeCode {
            changes.append(
                contentsOf: ConfigHarness.changes(claudeCode, current: currentClaudeCode, prefix: "claude_code"))
            risks.append(contentsOf: ConfigHarness.risks(claudeCode, current: currentClaudeCode, agent: agent))
        }
    }

    private static func planModelDefaults(
        _ desired: ModelDefaultsSection, current: ModelDefaultsSection?,
        into actions: inout [ConfigPlanAction]
    ) {
        let current = current ?? ModelDefaultsSection()
        var changes: [String] = []
        diff("core_model", desired: desired.coreModel, current: current.coreModel, into: &changes)
        diff(
            "compaction_model", desired: desired.compactionModel,
            current: current.compactionModel, into: &changes)
        guard !changes.isEmpty else { return }
        actions.append(
            ConfigPlanAction(
                section: ConfigSectionID.modelDefaults.rawValue, target: "model_defaults",
                kind: .update, changes: changes))
    }

    private static func planChat(
        _ desired: ChatSection, current: ChatSection?, into actions: inout [ConfigPlanAction]
    ) {
        let current = current ?? ChatSection()
        var changes: [String] = []
        diff("smooth_streaming", desired: desired.smoothStreaming, current: current.smoothStreaming, into: &changes)
        diff("group_activity", desired: desired.groupActivity, current: current.groupActivity, into: &changes)
        diff("expand_thinking", desired: desired.expandThinking, current: current.expandThinking, into: &changes)
        diff("spell_check", desired: desired.spellCheck, current: current.spellCheck, into: &changes)
        diff("auto_titles", desired: desired.autoTitles, current: current.autoTitles, into: &changes)
        diff(
            "follow_up_suggestions", desired: desired.followUpSuggestions,
            current: current.followUpSuggestions, into: &changes)
        diff(
            "clipboard_monitoring", desired: desired.clipboardMonitoring,
            current: current.clipboardMonitoring, into: &changes)
        diff("keep_mac_awake", desired: desired.keepMacAwake, current: current.keepMacAwake, into: &changes)
        guard !changes.isEmpty else { return }
        actions.append(ConfigPlanAction(section: "chat", target: "chat", kind: .update, changes: changes))
    }

    private static func planApp(
        _ desired: AppSection, current: AppSection?, into actions: inout [ConfigPlanAction]
    ) {
        let current = current ?? AppSection()
        var changes: [String] = []
        diff("hotkey", desired: desired.hotkey, current: current.hotkey, into: &changes)
        diff("start_at_login", desired: desired.startAtLogin, current: current.startAtLogin, into: &changes)
        diff(
            "show_notifications", desired: desired.showNotifications,
            current: current.showNotifications, into: &changes)
        guard !changes.isEmpty else { return }
        actions.append(ConfigPlanAction(section: "app", target: "app", kind: .update, changes: changes))
    }

    private static func planActiveAgent(
        _ desired: String, current: String, into actions: inout [ConfigPlanAction]
    ) {
        guard desired.lowercased() != current.lowercased() else { return }
        actions.append(
            ConfigPlanAction(
                section: ConfigSectionID.activeAgent.rawValue, target: desired, kind: .update,
                changes: ["new-chat agent: \(current) -> \(desired)"]))
    }

    // MARK: - Agents

    /// Plan lines for the portable per-agent keys (tools, groups, sandbox,
    /// subagents, working folder) on an existing agent. Group membership is
    /// compared by NAME against the local registry, so a document written
    /// on another machine reads as a change only when it would actually
    /// alter this agent.
    @MainActor
    private static func diffPortableSettings(
        _ entry: AgentEntry, agent: Agent, into changes: inout [String]
    ) {
        if let tools = entry.tools {
            let currentMode = (agent.toolSelectionMode ?? .auto).rawValue
            diff("tools.mode", desired: tools.mode, current: currentMode, into: &changes)
            if let enabled = tools.enabled {
                let groups = ToolRegistry.shared.portableToolGroups()
                let current = AgentToolSelectionResolver.export(
                    manualToolNames: agent.manualToolNames ?? [], groups: groups)
                if Set(enabled) != Set(current.toolNames) {
                    changes.append("tools.enabled: \(enabled.count) tool(s)")
                }
            }
        }
        if let mcp = entry.mcpServers {
            let groups = ToolRegistry.shared.portableToolGroups()
            let current = AgentToolSelectionResolver.export(
                manualToolNames: agent.manualToolNames ?? [], groups: groups)
            diffGroupList(
                "mcp_servers", desired: mcp,
                currentEnabled: current.enabledMCPServers, into: &changes)
        }
        if let plugins = entry.plugins {
            let groups = ToolRegistry.shared.portableToolGroups()
            let current = AgentToolSelectionResolver.export(
                manualToolNames: agent.manualToolNames ?? [], groups: groups)
            diffGroupList(
                "plugins", desired: plugins,
                currentEnabled: current.enabledPlugins, into: &changes)
        }
        switch entry.skills {
        case .absent:
            break
        case .null:
            if agent.skillNames != nil { changes.append("skills: every installed skill") }
        case .value(let names):
            let desired = Set(names.map { Skill.agentSkillsSlug(for: $0) })
            let current = agent.skillNames.map { Set($0.map { Skill.agentSkillsSlug(for: $0) }) }
            if current != desired {
                changes.append("skills: \(names.isEmpty ? "none" : names.joined(separator: ", "))")
            }
        }
        if let instructions = entry.pluginInstructions {
            diffMap(
                "plugin_instructions", desired: instructions,
                current: agent.pluginInstructions, defaultValue: "", into: &changes)
        }
        if let sandbox = entry.sandbox {
            let exec =
                agent.autonomousExec
                ?? AgentManager.shared.effectiveAutonomousExec(for: agent.id)
                ?? AutonomousExecConfig.default
            let effectiveOn = AgentManager.shared.effectiveAutonomousExec(for: agent.id)?.enabled ?? false
            diff("sandbox.enabled", desired: sandbox.enabled, current: effectiveOn, into: &changes)
            diff(
                "sandbox.network_enabled", desired: sandbox.networkEnabled,
                current: exec.sandboxNetworkEnabled, into: &changes)
            if let domains = sandbox.allowedDomains,
                Set(domains) != Set(exec.sandboxAllowedDomains ?? [])
            {
                changes.append("sandbox.allowed_domains: \(domains.count) domain(s)")
            }
            diff(
                "sandbox.max_commands_per_turn", desired: sandbox.maxCommandsPerTurn,
                current: exec.maxCommandsPerTurn, into: &changes)
            diff(
                "sandbox.background_process_enabled", desired: sandbox.backgroundProcessEnabled,
                current: exec.backgroundProcessEnabled, into: &changes)
            diff("sandbox.plugin_create", desired: sandbox.pluginCreate, current: exec.pluginCreate, into: &changes)
        }
        if let subagents = entry.subagents {
            diff(
                "subagents.enabled", desired: subagents.enabled,
                current: agent.settings.spawnDelegationEnabled, into: &changes)
            if let names = subagents.agents {
                let currentNames = agent.settings.spawnableAgentIDs.compactMap { id in
                    AgentManager.shared.agents.first { $0.id == id }?.name.lowercased()
                }
                if Set(names.map { $0.lowercased() }) != Set(currentNames) {
                    changes.append("subagents.agents: \(names.count) agent(s)")
                }
            }
        }
        diff("source_template", desired: entry.sourceTemplate, current: agent.sourceTemplateName, into: &changes)
        if let names = entry.workflows {
            let store = InstalledWorkflowStore.shared
            let desired = Set(names.compactMap { store.workflow(named: $0)?.id })
            let current = Set(agent.settings.enabledWorkflowIDs)
            let added = desired.subtracting(current).compactMap { store.workflow(id: $0)?.name }.sorted()
            let removed = current.subtracting(desired).compactMap { store.workflow(id: $0)?.name }.sorted()
            if !added.isEmpty { changes.append("workflows: +\(added.joined(separator: ", "))") }
            if !removed.isEmpty { changes.append("workflows: -\(removed.joined(separator: ", "))") }
        }
        switch entry.workingFolder {
        case .absent:
            break
        case .null:
            if agent.workingFolderPath != nil || agent.workingFolderBookmark != nil {
                changes.append("working_folder: \(display(agent.workingFolderPath)) -> null")
            }
        case .value(let raw):
            let expanded = (raw as NSString).expandingTildeInPath
            let current = agent.workingFolderPath.map { ($0 as NSString).expandingTildeInPath }
            if current != expanded || agent.workingFolderBookmark == nil {
                changes.append("working_folder: \(display(agent.workingFolderPath)) -> \(raw)")
            }
        }
        if let readOnly = entry.workingFolderReadOnly, readOnly != agent.settings.workingFolderReadOnly {
            changes.append("working_folder_read_only: \(agent.settings.workingFolderReadOnly) -> \(readOnly)")
        }
    }

    private static func diffGroupList(
        _ key: String, desired: AgentToolGroupsEntry, currentEnabled: [String],
        into changes: inout [String]
    ) {
        let current = Set(currentEnabled.map { $0.lowercased() })
        let turnOn = (desired.enabled ?? []).filter { !current.contains($0.lowercased()) }
        let turnOff = (desired.disabled ?? []).filter { current.contains($0.lowercased()) }
        if !turnOn.isEmpty { changes.append("\(key).enabled: +\(turnOn.joined(separator: ", "))") }
        if !turnOff.isEmpty { changes.append("\(key).disabled: -\(turnOff.joined(separator: ", "))") }
    }

    /// Create-time summary of the portable keys, so the approval card shows
    /// what the new agent will be able to reach.
    private static func summarizePortableSettings(_ entry: AgentEntry, into changes: inout [String]) {
        if entry.generationSettings.valueOrNil != nil { changes.append("generation_settings: configured") }
        if let show = entry.showResponseMetrics { changes.append("show_response_metrics: \(show)") }
        if entry.followUpSuggestions == false { changes.append("follow_up_suggestions: false") }
        if let avatar = entry.avatar, !avatar.isEmpty { changes.append("avatar: \(avatar)") }
        if let tools = entry.tools {
            if let mode = tools.mode { changes.append("tools.mode: \(mode)") }
            if let enabled = tools.enabled, !enabled.isEmpty {
                changes.append("tools: \(enabled.joined(separator: ", "))")
            }
        }
        if let on = entry.mcpServers?.enabled, !on.isEmpty {
            changes.append("mcp_servers: \(on.joined(separator: ", "))")
        }
        if let on = entry.plugins?.enabled, !on.isEmpty {
            changes.append("plugins: \(on.joined(separator: ", "))")
        }
        if let sandbox = entry.sandbox, let on = sandbox.enabled {
            changes.append("sandbox: \(on ? "on" : "off")")
        }
        if let subagents = entry.subagents, subagents.enabled == true {
            let targets = subagents.agents ?? []
            changes.append(
                "subagents: on" + (targets.isEmpty ? "" : " (\(targets.joined(separator: ", ")))"))
        }
        if let folder = entry.workingFolder.valueOrNil {
            changes.append("working_folder: \(folder)")
        }
        if entry.workingFolderReadOnly == true { changes.append("working_folder_read_only: true") }
        if let names = entry.workflows, !names.isEmpty {
            changes.append("workflows: \(names.joined(separator: ", "))")
        }
        if let caps = entry.capabilities,
            let data = try? JSONEncoder().encode(caps),
            let toggles = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?
                .compactMapValues({ $0 as? Bool })
        {
            let on = toggles.filter(\.value).keys.sorted()
            let off = toggles.filter { !$0.value }.keys.sorted()
            if !on.isEmpty { changes.append("capabilities on: \(on.joined(separator: ", "))") }
            if !off.isEmpty { changes.append("capabilities off: \(off.joined(separator: ", "))") }
        }
    }

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
                diff(
                    "generation_settings", desired: entry.generationSettings,
                    current: agent.generationSettings.map { ConfigField.value($0) } ?? .null, into: &changes)
                if let show = entry.showResponseMetrics, show != agent.settings.showResponseMetrics {
                    changes.append("show_response_metrics: \(agent.settings.showResponseMetrics) -> \(show)")
                }
                if let on = entry.followUpSuggestions, on != agent.settings.followUp.enabled {
                    changes.append("follow_up_suggestions: \(agent.settings.followUp.enabled) -> \(on)")
                }
                if let avatar = entry.avatar?.trimmingCharacters(in: .whitespacesAndNewlines),
                    (avatar.isEmpty ? nil : avatar) != agent.avatar
                {
                    changes.append("avatar: \(display(agent.avatar)) -> \(avatar.isEmpty ? "initial" : avatar)")
                }
                if let caps = entry.capabilities {
                    diffCapabilities(caps, agent: agent, into: &changes, risks: &risks)
                }
                diffPortableSettings(entry, agent: agent, into: &changes)
                diffRuntime(
                    entry.runtime, claudeCode: entry.claudeCode,
                    currentRuntime: agent.runtime, currentClaudeCode: agent.claudeCode ?? .default,
                    agent: entry.name, into: &changes, risks: &risks)
                if let desired = entry.sharedToolApproval, desired != (agent.sharedToolApproval ?? .deny) {
                    changes.append(Self.sharedToolApprovalChange(desired))
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
                if let description = entry.description {
                    changes.append("description: \(description)")
                }
                var risks: [String] = []
                if let model = entry.model.valueOrNil { changes.append("model: \(model)") }
                if let caps = entry.capabilities {
                    if caps.computerUseEnabled == true { risks.append(ConfigRisk.computerUse(entry.name)) }
                    if caps.browserUseEnabled == true { risks.append(ConfigRisk.browserUse(entry.name)) }
                    if caps.relayEnabled == true { risks.append(ConfigRisk.relayEnabled(entry.name)) }
                    if let apps = Self.appleApps(from: caps), !apps.isEmpty {
                        changes.append(
                            "apple_apps: enable " + AppleApp.sorted(apps).map(\.displayName).joined(separator: ", "))
                        risks.append(contentsOf: ConfigRisk.appleAppRisks(entry.name, current: [], desired: apps))
                    }
                }
                summarizePortableSettings(entry, into: &changes)
                if entry.orchestratorSpawnable == false {
                    changes.append("not added to the Orchestrator's delegation list")
                }
                diffRuntime(
                    entry.runtime, claudeCode: entry.claudeCode,
                    currentRuntime: nil, currentClaudeCode: .default,
                    agent: entry.name, into: &changes, risks: &risks)
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
            "image_enabled", desired: caps.imageEnabled,
            current: agent.settings.imageEnabled, into: &changes)
        diff(
            "applescript_enabled", desired: caps.applescriptEnabled,
            current: agent.settings.appleScriptEnabled, into: &changes)
        diff(
            "speak_enabled", desired: caps.speakEnabled,
            current: agent.settings.speakEnabled, into: &changes)
        diff(
            "render_chart_enabled", desired: caps.renderChartEnabled,
            current: agent.settings.renderChartEnabled, into: &changes)
        diff(
            "calculator_enabled", desired: caps.calculatorEnabled,
            current: agent.settings.calculatorEnabled, into: &changes)
        diff(
            "redaction_tools_enabled", desired: caps.redactionToolsEnabled,
            current: agent.settings.redactionToolsEnabled, into: &changes)
        diff(
            "task_checklist_enabled", desired: caps.taskChecklistEnabled,
            current: agent.settings.taskChecklistEnabled, into: &changes)
        diff(
            "clarify_enabled", desired: caps.clarifyEnabled,
            current: agent.settings.clarifyEnabled, into: &changes)
        diff(
            "artifacts_enabled", desired: caps.artifactsEnabled,
            current: agent.settings.artifactsEnabled, into: &changes)
        let currentRelay = RelayConfigurationStore.load().isEnabled(for: agent.id)
        diff("relay_enabled", desired: caps.relayEnabled, current: currentRelay, into: &changes)
        if let desiredApps = Self.appleApps(from: caps) {
            let current = agent.settings.enabledAppleApps
            if desiredApps != current {
                changes.append(contentsOf: appleAppsChangeLines(current: current, desired: desiredApps))
                risks.append(contentsOf: ConfigRisk.appleAppRisks(agent.name, current: current, desired: desiredApps))
            }
        }
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

    /// Resolve `capabilities.apple_apps` into the enum set (nil when the
    /// key is absent; unknown names were already rejected by `validate`).
    static func appleApps(from caps: AgentCapabilitiesEntry) -> Set<AppleApp>? {
        guard let raw = caps.appleApps else { return nil }
        return Set(raw.compactMap(AppleApp.parse))
    }

    /// Plan-card rows for an Apple apps change: one "enable …" and/or one
    /// "disable …" line naming the apps by display name.
    static func appleAppsChangeLines(current: Set<AppleApp>, desired: Set<AppleApp>) -> [String] {
        var lines: [String] = []
        let added = AppleApp.sorted(desired.subtracting(current))
        let removed = AppleApp.sorted(current.subtracting(desired))
        if !added.isEmpty {
            lines.append("apple_apps: enable " + added.map(\.displayName).joined(separator: ", "))
        }
        if !removed.isEmpty {
            lines.append("apple_apps: disable " + removed.map(\.displayName).joined(separator: ", "))
        }
        return lines
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
                if enabled, ToolRegistry.sandboxBackendAdapterToolNames.contains(tool) {
                    risks.append(ConfigRisk.sandboxAdapterEnabled(tool))
                }
            }
        }
        for (tool, raw) in (desired.policies ?? [:]).sorted(by: { $0.key < $1.key }) {
            guard let policy = ToolPermissionPolicy(rawValue: raw.lowercased()) else { continue }
            if !registry.isRegistered(tool) {
                notes.append("tools.policies[\(tool)]: no such tool is currently registered — skipped.")
                continue
            }
            let current =
                registry.configuredPolicy(for: tool) ?? registry.policyInfo(for: tool)?.defaultPolicy ?? .ask
            if current != policy {
                changes.append("\(tool): policy \(current.rawValue) -> \(policy.rawValue)")
                if policy == .auto {
                    if registry.requiresPerCallApproval(tool) {
                        risks.append(ConfigRisk.autoPolicyIgnoredPerCall(tool))
                    } else if registry.mayRequirePerCallApproval(tool) {
                        risks.append(ConfigRisk.autoPolicySendsStillAsk(tool))
                    } else {
                        risks.append(ConfigRisk.autoPolicy(tool))
                    }
                }
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
        diff(
            "applescript_execution_mode", desired: desired.applescriptExecutionMode?.lowercased(),
            current: current.applescriptExecutionMode, into: &changes)
        diffList(
            "spawnable_agents", desired: desired.spawnableAgents,
            current: current.spawnableAgents, into: &changes)
        diffList(
            "spawnable_workspace_agents",
            desired: desired.spawnableWorkspaceAgents?.map { $0.lowercased() },
            current: current.spawnableWorkspaceAgents?.map { $0.lowercased() }, into: &changes)
        for (key, autoJoin) in (desired.workspaceAutoJoin ?? [:]).sorted(by: { $0.key < $1.key }) {
            let currentValue = current.workspaceAutoJoin?[key] ?? true
            if autoJoin != currentValue {
                changes.append("workspace_auto_join[\(key)]: \(currentValue) → \(autoJoin)")
            }
        }
        for hint in desired.removedKeyHints { changes.append("(ignored) " + hint) }
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
            "budget_max_seconds", desired: desired.budgetMaxSeconds,
            current: current.budgetMaxSeconds, into: &changes)
        diff(
            "budget_max_parallel_spawns", desired: desired.budgetMaxParallelSpawns,
            current: current.budgetMaxParallelSpawns, into: &changes)
        diff(
            "budget_max_remote_parallel_spawns", desired: desired.budgetMaxRemoteParallelSpawns,
            current: current.budgetMaxRemoteParallelSpawns, into: &changes)
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
        // Replace-list semantics: an empty `spawnable_agents` wipes the pool.
        // Flag it whenever there is anything to lose — members today, or
        // custom agents that could be in it — so the approval card says
        // "the Orchestrator loses spawn_agent" instead of a bare list diff.
        if let pool = desired.spawnableAgents, pool.isEmpty {
            let removed = current.spawnableAgents?.count ?? 0
            let customAgents = AgentManager.shared.agents.filter { !$0.isBuiltIn }.count
            if removed > 0 || customAgents > 0 {
                risks.append(ConfigRisk.emptiesSpawnPool(removed: removed, customAgents: customAgents))
            }
        }
        if let pool = desired.spawnableWorkspaceAgents, pool.isEmpty,
            let removed = current.spawnableWorkspaceAgents?.count, removed > 0
        {
            risks.append(ConfigRisk.emptiesWorkspaceSpawnPool(removed: removed))
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

        let currentTargets = ConfigChannelPlatform.targets(in: current)
        for target in ConfigChannelPlatform.targets(in: desired) {
            let platform = target.platform
            let section = target.section
            let currentSection =
                currentTargets.first { $0.platform == platform && $0.connectionId == target.connectionId }?.section
                ?? ChannelPlatformSection()
            var changes: [String] = []
            var risks: [String] = []
            diff(
                "write_enabled", desired: section.writeEnabled,
                current: currentSection.writeEnabled, into: &changes)
            if section.writeEnabled == true && currentSection.writeEnabled != true {
                risks.append(ConfigRisk.channelWrites(target.label))
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
            if let raw = section.botTokenRef, case .success(let ref) = ConfigSecretRef.parse(raw) {
                changes.append("bot_token: store from \(ref.display)")
            }
            if let raw = section.appTokenRef, case .success(let ref) = ConfigSecretRef.parse(raw) {
                changes.append("app_token: store from \(ref.display)")
            }
            guard !changes.isEmpty else { continue }
            actions.append(
                ConfigPlanAction(
                    section: "channels", target: target.label, kind: .update,
                    changes: changes, risks: risks))
        }
    }

    // MARK: - Harness runtimes

    @MainActor
    private static func validateHarnessRuntimes(
        document: OsaurusConfigDocument, prune: Bool, into issues: inout [String]
    ) {
        guard let entries = document.harnessRuntimes else { return }
        var seen = Set<String>()
        for entry in entries {
            let key = ConfigHarness.normalizedName(entry.name)
            let label = "harness_runtimes[\(entry.name)]"
            if key.isEmpty {
                issues.append("harness_runtimes[]: every runtime needs a non-empty name.")
                continue
            }
            if key == ConfigHarness.builtInRuntimeKey {
                issues.append("\(label): `builtin` is reserved for Osaurus's own loop.")
            }
            if !seen.insert(key).inserted {
                issues.append("\(label): duplicate runtime name in document.")
            }
            let current = ConfigHarness.runtime(named: entry.name)
            if let raw = entry.kind {
                if let kind = ConfigHarness.kind(forKey: raw) {
                    if let current, current.kind != kind {
                        issues.append(
                            "\(label).kind: immutable after create — remove and re-add the runtime "
                                + "to change its protocol.")
                    }
                } else {
                    issues.append(
                        "\(label).kind: must be one of: \(ConfigHarness.kindKeys.joined(separator: ", ")).")
                }
            } else if current == nil {
                issues.append("\(label): `kind` is required to add a new runtime.")
            }
            if let executable = entry.executable,
                executable.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            {
                issues.append("\(label).executable: must not be empty.")
            }
            for name in (entry.environment ?? [:]).keys
            where name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                issues.append("\(label).environment: variable names must not be empty.")
            }
        }
    }

    /// `runtime` must name Osaurus's own loop or a runtime that exists after
    /// apply. Never falls back to the built-in loop: an agent the document
    /// meant for a harness would silently run somewhere else.
    @MainActor
    private static func checkRuntimeReference(
        _ runtime: String?, claudeCode: AgentClaudeCodeEntry?, label: String,
        document: OsaurusConfigDocument, prune: Bool, into issues: inout [String]
    ) {
        if let runtime {
            let key = ConfigHarness.normalizedName(runtime)
            if key != ConfigHarness.builtInRuntimeKey,
                !ConfigHarness.effectiveRuntimeNames(document: document, prune: prune).contains(key)
            {
                issues.append(
                    "\(label).runtime: runtime `\(runtime)` is not registered; add it under "
                        + "harness_runtimes, or use `builtin`.")
            }
        }
        if let raw = claudeCode?.mode, ConfigHarness.mode(forKey: raw) == nil {
            issues.append(
                "\(label).claude_code.mode: must be one of: \(ConfigHarness.modeKeys.joined(separator: ", ")).")
        }
        if let raw = claudeCode?.effort, ConfigHarness.effort(forKey: raw) == nil {
            issues.append(
                "\(label).claude_code.effort: must be one of: \(ConfigHarness.effortKeys.joined(separator: ", ")).")
        }
    }

    @MainActor
    private static func planHarnessRuntimes(
        _ entries: [HarnessRuntimeEntry], prune: Bool, into actions: inout [ConfigPlanAction]
    ) {
        let existing = HarnessRuntimeStore.shared.all()
        var matched = Set<UUID>()

        for entry in entries {
            let key = ConfigHarness.normalizedName(entry.name)
            if let runtime = existing.first(where: { ConfigHarness.normalizedName($0.displayName) == key }) {
                matched.insert(runtime.id)
                var changes: [String] = []
                var risks: [String] = []
                let executable = entry.executable ?? runtime.executable
                let arguments = entry.arguments ?? runtime.arguments
                if executable != runtime.executable {
                    changes.append("executable: \(runtime.executable) -> \(executable)")
                }
                if arguments != runtime.arguments {
                    changes.append("arguments: \(display(runtime.arguments)) -> \(display(arguments))")
                }
                if executable != runtime.executable || arguments != runtime.arguments {
                    risks.append(
                        ConfigRisk.harnessCommand(entry.name, ([executable] + arguments).joined(separator: " ")))
                }
                let envBefore = changes.count
                diffMap("environment", desired: entry.environment, current: runtime.environment, into: &changes)
                if changes.count > envBefore { risks.append(ConfigRisk.harnessEnvironment(entry.name)) }
                if !changes.isEmpty {
                    actions.append(
                        ConfigPlanAction(
                            section: "harness_runtimes", target: entry.name, kind: .update,
                            changes: changes, risks: risks))
                }
            } else {
                // Validation guarantees a kind for new runtimes.
                let kind = entry.kind.flatMap(ConfigHarness.kind(forKey:)) ?? .piRPC
                let executable = entry.executable ?? kind.defaultExecutable
                let arguments = entry.arguments ?? kind.defaultArguments
                let commandLine = ([executable] + arguments).joined(separator: " ")
                var changes = ["add \(ConfigHarness.key(for: kind)) runtime running: \(commandLine)"]
                for (name, value) in (entry.environment ?? [:]).sorted(by: { $0.key < $1.key }) {
                    changes.append("environment[\(name)]: \(value)")
                }
                actions.append(
                    ConfigPlanAction(
                        section: "harness_runtimes", target: entry.name, kind: .create,
                        changes: changes, risks: [ConfigRisk.harnessCommand(entry.name, commandLine)]))
            }
        }

        if prune {
            for runtime in existing where !matched.contains(runtime.id) {
                actions.append(
                    ConfigPlanAction(
                        section: "harness_runtimes", target: runtime.displayName, kind: .delete,
                        changes: ["remove runtime \(runtime.executable)"],
                        risks: [ConfigRisk.deleteHarnessRuntime(runtime.displayName)]))
            }
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
                if provider.transport == .http, let refs = entry.secretHeaderRefs {
                    for (header, raw) in refs.sorted(by: { $0.key < $1.key }) {
                        guard case .success(let ref) = ConfigSecretRef.parse(raw) else { continue }
                        changes.append("secret header \(header): store from \(ref.display)")
                    }
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
                            + "Settings → Tools & MCP → Services (secrets never travel through the document)")
                }
                for (header, raw) in (entry.secretHeaderRefs ?? [:]).sorted(by: { $0.key < $1.key }) {
                    guard case .success(let ref) = ConfigSecretRef.parse(raw) else { continue }
                    changes.append("secret header \(header): store from \(ref.display)")
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
        let installed = Set(ModelManager.shared.installedModels().map { $0.id })
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
}
