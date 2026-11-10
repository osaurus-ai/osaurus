//
//  CredentialMigration.swift
//  osaurus
//
//  One-way, copy-only import of agent-usable secrets from the legacy
//  Keychain services into the Keys store.
//
//  Hard rule: legacy Keychain items and consumer config files (`mcp.json`,
//  workflow installs, channel configs) are only ever READ here. Nothing is
//  deleted, overwritten, or rewritten, so an older beta pointed at the same
//  profile keeps working.
//
//  - Each legacy item is imported at most once (`importedLegacy` in the
//    index), so the pass is safe to re-run on every launch and after
//    plugins load; an interrupted pass resumes next time.
//  - An import never replaces a value already in the new store. Same key
//    and same value merge; a different value gets `<OWNER>_<KEY>` and the
//    consumer's slot is bound to it in `bindings.json`.
//

import AppKit
import Foundation

enum CredentialMigration {
    /// What exists right now, gathered on the main actor.
    struct Inputs: Sendable {
        struct Plugin: Sendable {
            let id: String
            let name: String
            let secretIds: [String]
        }

        struct Workflow: Sendable {
            let scope: UUID
            let name: String
            let keys: [String]
        }

        struct AgentChannel: Sendable {
            let id: String
            let name: String
        }

        var agentIds: Set<UUID> = []
        var plugins: [Plugin] = []
        var sandboxPlugins: [Plugin] = []
        var mcpProviders: [MCPProvider] = []
        var workflows: [Workflow] = []
        var agentChannels: [AgentChannel] = []
    }

    struct Report: Equatable, Sendable {
        var imported = 0
        var merged = 0
        var skipped = 0
        /// Items that could not be copied; while any remain, consumers keep
        /// reading the legacy stores underneath.
        var failed = 0
        /// A legacy listing wasn't authoritative (Keychain locked); the
        /// pass is retried on unlock.
        var listingIncomplete = false
    }

    // MARK: - Scheduling

    private static let runLock = NSLock()
    nonisolated(unsafe) private static var running = false
    nonisolated(unsafe) private static var rerunRequested = false

    /// Runs a pass off the main actor. Coalesces: a request while a pass is
    /// running queues exactly one more pass.
    @MainActor
    static func scheduleRun() {
        guard !KeychainQueryHelpers.disablesKeychainForProcess,
            !CredentialStore.current.usesMemorySecrets
        else { return }
        let shouldStart = runLock.withLock { () -> Bool in
            if running {
                rerunRequested = true
                return false
            }
            running = true
            return true
        }
        guard shouldStart else { return }
        let inputs = liveInputs()
        Task.detached(priority: .utility) {
            let report = run(inputs: inputs)
            if report.imported + report.merged + report.failed > 0 {
                NSLog(
                    "[Credentials] Import: \(report.imported) copied, \(report.merged) merged, "
                        + "\(report.skipped) skipped, \(report.failed) failed")
            }
            let again = runLock.withLock { () -> Bool in
                running = false
                defer { rerunRequested = false }
                return rerunRequested
            }
            await MainActor.run {
                if again { scheduleRun() } else { CredentialRegistry.shared.refresh() }
            }
        }
    }

    @MainActor
    static func liveInputs() -> Inputs {
        var inputs = Inputs()
        inputs.agentIds = Set(AgentManager.shared.agents.map(\.id))
        inputs.plugins = PluginManager.shared.plugins.map { loaded in
            Inputs.Plugin(
                id: loaded.plugin.id,
                name: loaded.plugin.manifest.name ?? loaded.plugin.id,
                secretIds: (loaded.plugin.manifest.secrets ?? []).map(\.id))
        }
        inputs.sandboxPlugins = SandboxPluginLibrary.shared.plugins.map {
            Inputs.Plugin(id: $0.id, name: $0.name, secretIds: $0.secrets ?? [])
        }
        inputs.mcpProviders = MCPProviderManager.shared.configuration.providers
        inputs.workflows = InstalledWorkflowStore.shared.workflows.map {
            Inputs.Workflow(scope: $0.id, name: $0.name, keys: $0.template.requirements.secrets.map(\.key))
        }
        inputs.agentChannels = AgentChannelConfigurationStore.load().connections.map {
            Inputs.AgentChannel(id: $0.id, name: $0.name)
        }
        return inputs
    }

    // MARK: - Pass

    typealias ToolListing = () -> (names: [String], isDefinitive: Bool)
    typealias AgentListing = () -> (entries: [(agentId: UUID, key: String)], isDefinitive: Bool)

    /// One import pass. Safe to call repeatedly. The pass only counts as
    /// complete when every item was copied and both legacy listings were
    /// authoritative: a locked Keychain lists nothing, which must not read
    /// as "nothing to import". Once complete, consumers stop reading the
    /// legacy stores; later passes still import items that appear.
    @discardableResult
    static func run(
        inputs: Inputs,
        store: CredentialStore = .current,
        toolListing: ToolListing = ToolSecretsKeychain.legacyAccountListing,
        agentListing: AgentListing = AgentSecretsKeychain.legacyEntries
    ) -> Report {
        var report = Report()
        store.retryRecoveryIfNeeded()
        let tools = toolListing()
        let toolAccounts = Set(tools.names)
        let agents = agentListing()
        report.listingIncomplete = !tools.isDefinitive || !agents.isDefinitive

        importChannels(toolAccounts: toolAccounts, inputs: inputs, store: store, report: &report)
        importPlugins(toolAccounts: toolAccounts, inputs: inputs, store: store, report: &report)
        importMCP(inputs: inputs, store: store, report: &report)
        importWorkflows(inputs: inputs, store: store, report: &report)
        importAgentSecrets(agents.entries, inputs: inputs, store: store, report: &report)

        if report.failed == 0, !report.listingIncomplete, store.migrationCompletedAt == nil {
            store.markMigrationCompleted()
        }
        return report
    }

    /// True until a pass completes (or while the index waits on the
    /// Keychain), so an unlock should trigger another pass.
    static var needsAnotherPass: Bool {
        let store = CredentialStore.current
        return store.migrationCompletedAt == nil
            || store.loadIssues().contains { if case .indexRecoveryPending = $0 { true } else { false } }
    }

    private nonisolated(unsafe) static var unlockObservers: [NSObjectProtocol] = []

    /// Runs another pass when the Mac is unlocked or the session becomes
    /// active, while a pass is still owed (the Keychain was locked).
    @MainActor
    static func observeUnlock() {
        guard unlockObservers.isEmpty else { return }
        let handler: @Sendable (Foundation.Notification) -> Void = { _ in
            Task { @MainActor in if needsAnotherPass { scheduleRun() } }
        }
        unlockObservers = [
            DistributedNotificationCenter.default().addObserver(
                forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: .main, using: handler),
            NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.sessionDidBecomeActiveNotification, object: nil, queue: .main, using: handler),
        ]
    }

    // MARK: - Sources

    private static func importChannels(
        toolAccounts: Set<String>, inputs: Inputs, store: CredentialStore, report: inout Report
    ) {
        let defaultPrefix = "\(Agent.defaultId.uuidString)."
        for pluginId in [SlackCredentialStore.pluginId, DiscordCredentialStore.pluginId, TelegramCredentialStore.pluginId]
        {
            let prefix = "\(defaultPrefix)\(pluginId)."
            var keys = Set(toolAccounts.filter { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count)) })
            // Pre-agent-scoping accounts (`<plugin>.<key>`) for the fixed keys.
            for key in ["bot_token", "signing_secret", "app_token"] where toolAccounts.contains("\(pluginId).\(key)") {
                keys.insert(key)
            }
            for key in keys.sorted() {
                let slot: CredentialSlot
                switch pluginId {
                case SlackCredentialStore.pluginId: slot = SlackCredentialStore.slot(for: key)
                case DiscordCredentialStore.pluginId:
                    guard key == DiscordCredentialStore.botTokenKey else { continue }
                    slot = ChannelCredentialSlots.discordBotToken
                default:
                    guard key == TelegramCredentialStore.botTokenKey else { continue }
                    slot = ChannelCredentialSlots.telegramBotToken
                }
                importGlobal(
                    legacyId: ChannelCredentials.legacyId(pluginId: pluginId, key: key),
                    slot: slot, owner: slot.consumer, origin: .channel, store: store, report: &report
                ) { ToolSecretsKeychain.readOnlySecret(id: key, for: pluginId, agentId: Agent.defaultId) }
            }
        }

        let names = Dictionary(inputs.agentChannels.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
        let channelPrefix = "\(defaultPrefix)\(ChannelCredentials.agentChannelPluginIdPrefix)."
        for account in toolAccounts.sorted() where account.hasPrefix(channelPrefix) {
            let rest = account.dropFirst(channelPrefix.count)
            guard let dot = rest.firstIndex(of: ".") else { continue }
            let connectionId = String(rest[..<dot])
            let secretName = String(rest[rest.index(after: dot)...])
            guard !connectionId.isEmpty, !secretName.isEmpty else { continue }
            let pluginId = ChannelCredentials.agentChannelPluginId(connectionId)
            let slot = ChannelCredentialSlots.agentChannel(
                connectionId: connectionId, connectionName: names[connectionId] ?? connectionId,
                secretName: secretName)
            importGlobal(
                legacyId: ChannelCredentials.legacyId(pluginId: pluginId, key: secretName),
                slot: slot, owner: connectionId, origin: .channel, store: store, report: &report
            ) { ToolSecretsKeychain.readOnlySecret(id: secretName, for: pluginId, agentId: Agent.defaultId) }
        }
    }

    /// Declared plugin secrets (native manifests and sandbox plugins). The
    /// Default agent's namespace was "global"; other agents' are overrides.
    private static func importPlugins(
        toolAccounts: Set<String>, inputs: Inputs, store: CredentialStore, report: inout Report
    ) {
        let agentsInTools = Set(
            toolAccounts.compactMap { account -> UUID? in
                guard account.count > 37 else { return nil }
                return UUID(uuidString: String(account.prefix(36)))
            })
        for plugin in inputs.plugins + inputs.sandboxPlugins {
            for specId in plugin.secretIds {
                let slot = PluginCredentials.slot(pluginId: plugin.id, pluginName: plugin.name, specId: specId)
                let owner = CredentialKeys.pluginOwner(plugin.id)
                let globalAccount = "\(Agent.defaultId.uuidString).\(plugin.id).\(specId)"
                if toolAccounts.contains(globalAccount) || toolAccounts.contains("\(plugin.id).\(specId)") {
                    importGlobal(
                        legacyId: ToolSecretsKeychain.legacyId(
                            agentId: Agent.defaultId, pluginId: plugin.id, key: specId),
                        slot: slot, owner: owner, origin: .plugin, store: store, report: &report
                    ) { ToolSecretsKeychain.readOnlySecret(id: specId, for: plugin.id, agentId: Agent.defaultId) }
                }
                for agentId in agentsInTools.sorted(by: { $0.uuidString < $1.uuidString })
                where agentId != Agent.defaultId
                    && toolAccounts.contains("\(agentId.uuidString).\(plugin.id).\(specId)")
                {
                    guard inputs.agentIds.isEmpty || inputs.agentIds.contains(agentId) else { continue }
                    importAgent(
                        legacyId: ToolSecretsKeychain.legacyId(agentId: agentId, pluginId: plugin.id, key: specId),
                        key: slot.effectiveKey(in: store), agentId: agentId, origin: .plugin,
                        exposeToSandbox: false, store: store, report: &report
                    ) { ToolSecretsKeychain.readOnlySecret(id: specId, for: plugin.id, agentId: agentId) }
                }
            }
        }
    }

    private static func importMCP(inputs: Inputs, store: CredentialStore, report: inout Report) {
        for provider in inputs.mcpProviders {
            for name in provider.secretEnvKeys {
                let slot = MCPCredentials.envSlot(provider, name: name)
                importGlobal(
                    legacyId: MCPCredentials.legacyId(providerId: provider.id, suffix: "env.\(name)"),
                    slot: slot, owner: provider.name, origin: .mcp, pin: true, store: store, report: &report
                ) { MCPProviderKeychain.getEnvSecret(key: name, for: provider.id) }
            }
            for header in provider.secretHeaderKeys {
                let slot = MCPCredentials.headerSlot(provider, header: header)
                importGlobal(
                    legacyId: MCPCredentials.legacyId(providerId: provider.id, suffix: "header.\(header)"),
                    slot: slot, owner: provider.name, origin: .mcp, pin: true, store: store, report: &report
                ) { MCPProviderKeychain.getHeaderSecret(key: header, for: provider.id) }
            }
            if provider.transport == .http {
                importGlobal(
                    legacyId: MCPCredentials.legacyId(providerId: provider.id, suffix: "token"),
                    slot: MCPCredentials.tokenSlot(provider), owner: provider.name, origin: .mcp, pin: true,
                    store: store, report: &report
                ) { MCPProviderKeychain.getToken(for: provider.id) }
            }
        }
    }

    private static func importWorkflows(inputs: Inputs, store: CredentialStore, report: inout Report) {
        for workflow in inputs.workflows {
            for key in workflow.keys {
                let slot = WorkflowCredentials.slot(scope: workflow.scope, key: key, workflowName: workflow.name)
                importGlobal(
                    legacyId: WorkflowCredentials.legacyId(scope: workflow.scope, key: key),
                    slot: slot, owner: workflow.name, origin: .workflow, store: store, report: &report
                ) { WorkflowSecretsKeychain.read(account: WorkflowSecretsKeychain.secretAccount(scope: workflow.scope, key: key)) }
            }
        }
    }

    /// Agent secrets (`sandbox_secret_set`, the secret prompt, the agent's
    /// Sandbox page) become that agent's own keys, usable when running code.
    private static func importAgentSecrets(
        _ entries: [(agentId: UUID, key: String)], inputs: Inputs, store: CredentialStore, report: inout Report
    ) {
        for (agentId, key) in entries {
            guard inputs.agentIds.isEmpty || inputs.agentIds.contains(agentId) else { continue }
            guard CredentialKeys.isValid(key) else {
                report.skipped += 1
                continue
            }
            importAgent(
                legacyId: AgentSecretsKeychain.legacyId(agentId: agentId, key: key),
                key: key, agentId: agentId, origin: .sandboxPrompt, exposeToSandbox: true,
                store: store, report: &report
            ) { AgentSecretsKeychain.getSecret(id: key, agentId: agentId) }
        }
    }

    // MARK: - Import primitives

    private static func importGlobal(
        legacyId: String, slot: CredentialSlot, owner: String, origin: CredentialOrigin, pin: Bool = false,
        store: CredentialStore, report: inout Report, read: () -> String?
    ) {
        guard !store.hasImportedLegacy(legacyId) else { return }
        if store.isDeleted(slot.effectiveKey(in: store), scope: .global) {
            // Deleted on the Keys page before this item was imported.
            store.markLegacyImported([legacyId])
            report.skipped += 1
            return
        }
        guard let value = read(), !value.isEmpty else { return }

        let boundKey = store.boundKey(for: slot.id)
        for key in Set([boundKey, slot.defaultKey].compactMap { $0 }) {
            store.adoptStoredSecret(key, scope: .global)
        }
        if let boundKey, store.hasValue(boundKey, scope: .global) {
            // The user already set this slot up in the new store.
            store.markLegacyImported([legacyId])
            report.skipped += 1
            return
        }
        var target = store.nonConflictingKey(for: slot, value: value, owner: owner)
        while store.adoptStoredSecret(target, scope: .global) {
            target = store.nonConflictingKey(for: slot, value: value, owner: owner)
        }
        if store.hasValue(target, scope: .global) {
            report.merged += 1
        } else {
            let outcome = store.save(
                target, scope: .global, value: value, kind: .secret, exposeToSandbox: false, origin: origin)
            guard outcome.isSuccess else {
                report.failed += 1
                return
            }
            report.imported += 1
        }
        if pin || target != slot.effectiveKey(in: store) {
            store.setBinding(slot: slot.id, key: target, defaultKey: pin ? nil : slot.defaultKey)
        }
        store.markLegacyImported([legacyId])
    }

    private static func importAgent(
        legacyId: String, key: String, agentId: UUID, origin: CredentialOrigin, exposeToSandbox: Bool,
        store: CredentialStore, report: inout Report, read: () -> String?
    ) {
        guard !store.hasImportedLegacy(legacyId) else { return }
        if store.isDeleted(key, scope: .agent(agentId)) {
            store.markLegacyImported([legacyId])
            report.skipped += 1
            return
        }
        guard let value = read(), !value.isEmpty else { return }
        store.adoptStoredSecret(key, scope: .agent(agentId))
        if store.hasValue(key, scope: .agent(agentId)) {
            store.markLegacyImported([legacyId])
            report.skipped += 1
            return
        }
        let outcome = store.save(
            key, scope: .agent(agentId), value: value, kind: .secret, exposeToSandbox: exposeToSandbox,
            origin: origin)
        guard outcome.isSuccess else {
            report.failed += 1
            return
        }
        report.imported += 1
        store.markLegacyImported([legacyId])
    }
}
