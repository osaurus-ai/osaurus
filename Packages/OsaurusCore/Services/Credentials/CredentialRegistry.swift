//
//  CredentialRegistry.swift
//  osaurus
//
//  The read model behind Management → Keys: every key in the store, who
//  uses it, what is missing, app/provider keys kept in their own stores
//  (`AppKeys`), and signed-in accounts. Built from presence checks only;
//  values are read on demand (Show / Copy) through `CredentialReveal`.
//

import Combine
import Foundation

/// A consumer slot plus a cheap check for a value the import has not
/// copied yet, so a slot served by the legacy fallback is not "missing".
struct CredentialSlotEntry: Sendable {
    let slot: CredentialSlot
    let legacy: [CredentialResolver.LegacyItem]

    init(_ slot: CredentialSlot, legacy: [CredentialResolver.LegacyItem] = []) {
        self.slot = slot
        self.legacy = legacy
    }
}

/// One key on the page.
public struct CredentialKeyRow: Identifiable, Equatable, Sendable {
    public let key: String
    /// The value shared by every agent, if any.
    public let global: CredentialRecord?
    /// Per-agent values (overrides of `global`, or agent-only keys).
    public let agentRecords: [CredentialRecord]
    /// Consumers bound to this key.
    public let usedBy: [CredentialSlot]

    public var id: String { key }
    public var kind: CredentialKind { global?.kind ?? agentRecords.first?.kind ?? .secret }

    public func record(for agentId: UUID) -> CredentialRecord? {
        agentRecords.first { $0.scope.agentId == agentId }
    }
}

/// A required consumer slot with no shared value.
public struct CredentialMissingKey: Identifiable, Equatable, Sendable {
    public let slot: CredentialSlot
    public let key: String
    /// Agents with their own value for `key`: their runs have it, while
    /// runs without an agent (and every other agent) still need a shared one.
    public var agentsWithOwnValue: [UUID] = []

    public var id: String { slot.id }
    /// "GitHub server needs GITHUB_TOKEN".
    public var summary: String { "\(slot.consumer) needs \(key)" }
}

/// An OAuth sign-in owned by its connection.
public struct SignedInAccountRow: Identifiable, Equatable, Sendable {
    public enum Owner: Hashable, Sendable {
        case mcp(UUID)
        case remoteProvider(UUID)
    }

    public let owner: Owner
    public let title: String
    public let detail: String
    public let isSignedIn: Bool

    public var id: String {
        switch owner {
        case .mcp(let id): return "mcp:\(id.uuidString)"
        case .remoteProvider(let id): return "remote:\(id.uuidString)"
        }
    }
}

@MainActor
public final class CredentialRegistry: ObservableObject {
    public static let shared = CredentialRegistry()

    @Published public private(set) var rows: [CredentialKeyRow] = []
    @Published public private(set) var missing: [CredentialMissingKey] = []
    @Published public private(set) var appKeys: [AppKeyRow] = []
    @Published public private(set) var signedInAccounts: [SignedInAccountRow] = []
    @Published public private(set) var loadIssues: [CredentialLoadIssue] = []

    private var observers: [NSObjectProtocol] = []
    private var refreshTask: Task<Void, Never>?
    private var generation = 0
    /// Set while the Keys page is on screen; app keys and signed-in
    /// accounts are only probed then.
    public var isPageVisible = false
    /// Agent the Keys page should show when it next opens.
    @Published public var focusAgentId: UUID?

    private init() {
        let sources: [(Foundation.Notification.Name, AnyObject?)] = [
            (.credentialsDidChange, CredentialStore.shared), (.toolsListChanged, nil),
        ]
        for (name, object) in sources {
            observers.append(
                NotificationCenter.default.addObserver(forName: name, object: object, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.refresh() }
                })
        }
        // The text-to-speech engine decides whether its key is listed.
        observers.append(
            NotificationCenter.default.addObserver(forName: .ttsConfigurationChanged, object: nil, queue: .main) {
                [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.isPageVisible else { return }
                    self.refresh()
                }
            })
        // Installing, rebinding, or removing a workflow changes which keys
        // are missing without touching the store or the tool list.
        workflowsObserver = InstalledWorkflowStore.shared.$workflows.dropFirst()
            .receive(on: DispatchQueue.main)  // `@Published` emits before the new value is stored.
            .sink { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            }
    }

    private var workflowsObserver: AnyCancellable?

    /// Rebuilds the page. Presence checks that may hit the Keychain run off
    /// the main actor; the latest call wins. App keys and signed-in
    /// accounts are only refreshed while the page is visible (or `full`).
    public func refresh(full: Bool = false) {
        generation += 1
        let token = generation
        let includeExtras = full || isPageVisible
        let slots = Self.liveSlots()
        let appKeyInputs = includeExtras ? Self.liveAppKeyInputs() : []
        let accountInputs = includeExtras ? Self.liveAccountInputs() : []
        let store = CredentialStore.current
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            let built = await Task.detached(priority: .userInitiated) {
                (
                    rows: Self.buildRows(slots: slots.map(\.slot), store: store),
                    missing: Self.buildMissing(slots: slots, store: store),
                    appKeys: appKeyInputs.compactMap { $0.resolve() },
                    accounts: accountInputs.map { $0.resolve() },
                    issues: store.loadIssues()
                )
            }.value
            guard let self, !Task.isCancelled, token == self.generation else { return }
            self.loadIssues = built.issues
            self.rows = built.rows
            self.missing = built.missing
            if includeExtras {
                self.appKeys = built.appKeys
                self.signedInAccounts = built.accounts
            }
            ManagementBadgeStore.shared.setMissingKeysCount(built.missing.count)
        }
    }

    // MARK: - Pure builders

    nonisolated static func buildRows(slots: [CredentialSlot], store: CredentialStore) -> [CredentialKeyRow] {
        var usedBy: [String: [CredentialSlot]] = [:]
        for slot in slots { usedBy[slot.effectiveKey(in: store), default: []].append(slot) }
        var globals: [String: CredentialRecord] = [:]
        var agents: [String: [CredentialRecord]] = [:]
        for record in store.allRecords() {
            switch record.scope {
            case .global: globals[record.key] = record
            case .agent: agents[record.key, default: []].append(record)
            }
        }
        let keys = Set(globals.keys).union(agents.keys)
        return keys.sorted().map { key in
            CredentialKeyRow(
                key: key, global: globals[key], agentRecords: agents[key] ?? [],
                usedBy: (usedBy[key] ?? []).sorted { (a: CredentialSlot, b: CredentialSlot) in
                    a.consumer == b.consumer ? a.field < b.field : a.consumer < b.consumer
                })
        }
    }

    nonisolated static func buildMissing(slots: [CredentialSlotEntry], store: CredentialStore) -> [CredentialMissingKey] {
        var seen = Set<String>()
        var out: [CredentialMissingKey] = []
        var agentsByKey: [String: [UUID]]?
        for entry in slots where entry.slot.required && seen.insert(entry.slot.id).inserted {
            if CredentialResolver.isSatisfied(entry.slot, agentId: nil, legacy: entry.legacy, store: store) {
                continue
            }
            if agentsByKey == nil {
                var byKey: [String: [UUID]] = [:]
                for record in store.allRecords() {
                    if case .agent(let id) = record.scope { byKey[record.key, default: []].append(id) }
                }
                agentsByKey = byKey
            }
            let key = entry.slot.effectiveKey(in: store)
            out.append(CredentialMissingKey(slot: entry.slot, key: key, agentsWithOwnValue: agentsByKey?[key] ?? []))
        }
        return out.sorted { (a: CredentialMissingKey, b: CredentialMissingKey) in
            a.slot.consumer == b.slot.consumer ? a.key < b.key : a.slot.consumer < b.slot.consumer
        }
    }

    // MARK: - Live inputs

    /// Every slot an installed consumer declares, with the legacy items
    /// each consumer reads for it.
    static func liveSlots() -> [CredentialSlotEntry] {
        var out: [CredentialSlotEntry] = []

        for provider in MCPProviderManager.shared.configuration.providers {
            let id = provider.id
            for name in provider.transport == .stdio ? provider.secretEnvKeys : [] {
                out.append(
                    CredentialSlotEntry(
                        MCPCredentials.envSlot(provider, name: name),
                        legacy: [MCPCredentials.envLegacy(providerId: id, name: name)]))
            }
            for header in provider.transport == .stdio ? [] : provider.secretHeaderKeys {
                out.append(
                    CredentialSlotEntry(
                        MCPCredentials.headerSlot(provider, header: header),
                        legacy: [MCPCredentials.headerLegacy(providerId: id, header: header)]))
            }
            if provider.transport != .stdio, provider.authType == .bearerToken {
                out.append(
                    CredentialSlotEntry(
                        MCPCredentials.tokenSlot(provider), legacy: [MCPCredentials.tokenLegacy(providerId: id)]))
            }
        }

        let plugins: [(id: String, name: String, secrets: [(id: String, required: Bool)])] =
            PluginManager.shared.plugins.map { loaded in
                (
                    loaded.plugin.id, loaded.plugin.manifest.name ?? loaded.plugin.id,
                    (loaded.plugin.manifest.secrets ?? []).map { ($0.id, $0.required) }
                )
            }
            + SandboxPluginLibrary.shared.plugins.map { plugin in
                (plugin.id, plugin.name, (plugin.secrets ?? []).map { ($0, true) })
            }
        for plugin in plugins {
            for secret in plugin.secrets {
                out.append(
                    CredentialSlotEntry(
                        PluginCredentials.slot(
                            pluginId: plugin.id, pluginName: plugin.name, specId: secret.id, required: secret.required),
                        legacy: PluginCredentials.legacyItems(pluginId: plugin.id, specId: secret.id, agentId: nil)))
            }
        }

        for workflow in InstalledWorkflowStore.shared.workflows {
            for secret in workflow.template.requirements.secrets where secret.oauth2 == nil {
                if let bound = workflow.bindings.secrets[secret.key],
                    WorkflowSecretsKeychain.isConnectionAccount(bound)
                {
                    continue
                }
                out.append(
                    CredentialSlotEntry(
                        WorkflowCredentials.slot(scope: workflow.id, key: secret.key, workflowName: workflow.name),
                        legacy: [WorkflowCredentials.legacyItem(scope: workflow.id, key: secret.key)]))
            }
        }

        let enabledChannels = Set(
            AgentChannelConfigurationStore.load().connections.filter(\.enabled).map(\.id))
        let channels: [(String, String, String, CredentialSlot)] = [
            (AgentChannelConnection.nativeSlackConnectionId, SlackCredentialStore.pluginId,
             SlackCredentialStore.botTokenKey, ChannelCredentialSlots.slackBotToken),
            (AgentChannelConnection.nativeDiscordConnectionId, DiscordCredentialStore.pluginId,
             DiscordCredentialStore.botTokenKey, ChannelCredentialSlots.discordBotToken),
            (AgentChannelConnection.nativeTelegramConnectionId, TelegramCredentialStore.pluginId,
             TelegramCredentialStore.botTokenKey, ChannelCredentialSlots.telegramBotToken),
        ]
        for (connectionId, pluginId, key, slot) in channels where enabledChannels.contains(connectionId) {
            out.append(CredentialSlotEntry(slot, legacy: [ChannelCredentials.legacyItem(pluginId: pluginId, key: key)]))
        }
        return out
    }

    struct AccountInput: Sendable {
        let owner: SignedInAccountRow.Owner
        let title: String
        let detail: String

        func resolve() -> SignedInAccountRow {
            let signedIn: Bool
            switch owner {
            case .mcp(let id): signedIn = MCPProviderKeychain.oauthTokensAvailability(for: id) == .present
            case .remoteProvider(let id): signedIn = RemoteProviderKeychain.oauthTokensAvailability(for: id) == .present
            }
            return SignedInAccountRow(owner: owner, title: title, detail: detail, isSignedIn: signedIn)
        }
    }

    static func liveAccountInputs() -> [AccountInput] {
        var out: [AccountInput] = []
        for provider in MCPProviderManager.shared.configuration.providers where provider.authType == .oauth {
            out.append(AccountInput(owner: .mcp(provider.id), title: provider.name, detail: "MCP server"))
        }
        for provider in RemoteProviderManager.shared.configuration.providers where provider.authType != .apiKey {
            out.append(AccountInput(owner: .remoteProvider(provider.id), title: provider.name, detail: "Model provider"))
        }
        return out
    }
}
