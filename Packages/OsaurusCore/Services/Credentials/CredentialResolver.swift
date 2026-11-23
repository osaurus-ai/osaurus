//
//  CredentialResolver.swift
//  osaurus
//
//  THE resolution rule for every agent-usable credential: the agent's own
//  value if it has one, otherwise the global value. Consumers go through
//  here instead of reading a store directly.
//

import Foundation

public enum CredentialResolver {
    /// Env var names a credential may never override in a sandbox exec.
    static let reservedEnvVarNames: Set<String> = [
        "PATH", "HOME", "SHELL", "USER", "LOGNAME",
        "VIRTUAL_ENV", "OSAURUS_PLUGIN", "NODE_PATH",
    ]
    /// Loader variables (`LD_PRELOAD`, `DYLD_INSERT_LIBRARIES`, …) change
    /// what code runs, so every name with these prefixes is reserved.
    static let reservedEnvVarPrefixes = ["LD_", "DYLD_"]

    public static func isReservedEnvVar(_ name: String) -> Bool {
        let upper = name.uppercased()
        return reservedEnvVarNames.contains(upper) || reservedEnvVarPrefixes.contains { upper.hasPrefix($0) }
    }

    // MARK: - Single keys

    /// The record that supplies `key` for `agentId`.
    public static func effectiveRecord(
        _ key: String, agentId: UUID?, store: CredentialStore = .current
    ) -> CredentialRecord? {
        if let agentId, let record = store.record(key, scope: .agent(agentId)) { return record }
        return store.record(key, scope: .global)
    }

    public static func value(_ key: String, agentId: UUID?, store: CredentialStore = .current) -> String? {
        if let agentId, let value = store.value(key, scope: .agent(agentId)) { return value }
        return store.value(key, scope: .global)
    }

    public static func source(
        _ key: String, agentId: UUID?, store: CredentialStore = .current
    ) -> CredentialValueSource? {
        if let agentId, store.hasValue(key, scope: .agent(agentId)) { return .agent }
        if store.hasValue(key, scope: .global) { return .global }
        return nil
    }

    // MARK: - Slots

    /// An item saved before the Keys store that may fill a key until the
    /// migration imports it. Read only while migration is incomplete, the
    /// item is unimported, and the user has not deleted the key.
    public struct LegacyItem: Sendable {
        let id: String
        let read: @Sendable () -> String?

        public init(_ id: String, read: @escaping @Sendable () -> String?) {
            self.id = id
            self.read = read
        }
    }

    /// `key` for `agentId`: the agent's value, the global value, then the
    /// first non-empty legacy item.
    public static func resolve(
        _ key: String, agentId: UUID?, legacy: [LegacyItem] = [], store: CredentialStore = .current
    ) -> String? {
        if let value = value(key, agentId: agentId, store: store), !value.isEmpty { return value }
        return legacyValue(key, agentId: agentId, legacy: legacy, store: store)
    }

    public static func resolve(
        _ slot: CredentialSlot, agentId: UUID?, legacy: [LegacyItem] = [], store: CredentialStore = .current
    ) -> String? {
        resolve(slot.effectiveKey(in: store), agentId: agentId, legacy: legacy, store: store)
    }

    /// Presence for `slot`: the index, then the legacy items.
    public static func isSatisfied(
        _ slot: CredentialSlot, agentId: UUID?, legacy: [LegacyItem] = [], store: CredentialStore = .current
    ) -> Bool {
        let key = slot.effectiveKey(in: store)
        if source(key, agentId: agentId, store: store) != nil { return true }
        return legacyValue(key, agentId: agentId, legacy: legacy, store: store) != nil
    }

    /// Presence for `slot` from the index plus a caller-supplied legacy
    /// check (for checks that must not read the Keychain inline). The check
    /// runs only while `legacyId` may still be read for `slot`'s key.
    static func isSatisfied(
        _ slot: CredentialSlot, agentId: UUID?, legacyId: String, store: CredentialStore = .current,
        legacyPresent: () -> Bool
    ) -> Bool {
        let key = slot.effectiveKey(in: store)
        if source(key, agentId: agentId, store: store) != nil { return true }
        return mayUseLegacy(legacyId, for: key, agentId: agentId, store: store) && legacyPresent()
    }

    /// Removes slot bindings. The credentials stay.
    static func forget<S: Sequence>(slots: S, store: CredentialStore = .current) where S.Element == String {
        for slot in slots { store.setBinding(slot: slot, key: nil) }
    }

    private static func legacyValue(
        _ key: String, agentId: UUID?, legacy: [LegacyItem], store: CredentialStore
    ) -> String? {
        guard !legacy.isEmpty, readsLegacy(store), !wasDeleted(key, agentId: agentId, store: store) else { return nil }
        for item in legacy where !store.hasImportedLegacy(item.id) {
            if let value = item.read(), !value.isEmpty { return value }
        }
        return nil
    }

    /// Whether `legacyId` may still stand in for `key` where `agentId` reads it.
    static func mayUseLegacy(_ legacyId: String, for key: String, agentId: UUID?, store: CredentialStore = .current)
        -> Bool
    {
        mayReadLegacy(legacyId, store: store) && !wasDeleted(key, agentId: agentId, store: store)
    }

    /// Whether the user deleted `key` where `agentId` reads it, which turns
    /// the legacy fallback off for it.
    static func wasDeleted(_ key: String, agentId: UUID?, store: CredentialStore) -> Bool {
        if store.isDeleted(key, scope: .global) { return true }
        guard let agentId else { return false }
        return store.isDeleted(key, scope: .agent(agentId))
    }

    /// Whether legacy stores may still hold values the Keys store lacks:
    /// true until a migration pass copies everything.
    static func readsLegacy(_ store: CredentialStore) -> Bool {
        store.migrationCompletedAt == nil
    }

    /// Whether a legacy item may still be read: migration is incomplete and
    /// the item has not been imported or handled.
    static func mayReadLegacy(_ legacyId: String, store: CredentialStore = .current) -> Bool {
        readsLegacy(store) && !store.hasImportedLegacy(legacyId)
    }

    /// Bulk legacy entries that may still apply: none once migration is
    /// complete (`entries` is then never evaluated), otherwise those not
    /// imported, deleted, or reserved.
    private static func legacyEntries(
        _ entries: @autoclosure () -> [String: String], store: CredentialStore,
        legacyId: (String) -> String, isDeleted: (String) -> Bool
    ) -> [String: String] {
        guard readsLegacy(store) else { return [:] }
        return entries().filter { key, _ in
            !isReservedEnvVar(key) && !store.hasImportedLegacy(legacyId(key)) && !isDeleted(key)
        }
    }

    // MARK: - Request agent

    /// The agent whose private keys a sandbox or plugin call may use: nil
    /// (shared keys only) for a run that uses no agent's keys, else the
    /// request's agent, else `fallback` (the agent the tool was registered for).
    public static func credentialAgent(fallback: UUID?) -> UUID? {
        if ChatExecutionContext.usesSharedKeysOnly { return nil }
        return ChatExecutionContext.currentAgentId ?? fallback
    }

    // MARK: - Agent views

    /// One record per key: the agent's when present, else the global one.
    public static func effectiveRecords(agentId: UUID?, store: CredentialStore = .current) -> [CredentialRecord] {
        var byKey: [String: CredentialRecord] = [:]
        for record in store.allRecords() {
            switch record.scope {
            case .global:
                if byKey[record.key] == nil { byKey[record.key] = record }
            case .agent(let id) where id == agentId:
                byKey[record.key] = record
            case .agent:
                continue
            }
        }
        return byKey.values.sorted { $0.key < $1.key }
    }

    /// Env vars for an agent's sandbox exec: every effective credential the
    /// user allowed agents to use when running code, minus reserved names.
    /// Before the first migration pass completes, unimported legacy agent
    /// secrets are added underneath so nothing disappears mid-upgrade.
    /// A nil agent gets the keys shared by all agents only.
    public static func sandboxEnvironment(agentId: UUID?, store: CredentialStore = .current) -> [String: String] {
        var env: [String: String] = [:]
        if let agentId {
            env = legacyEntries(
                AgentSecretsKeychain.legacyFilteredSecrets(agentId: agentId), store: store,
                legacyId: { AgentSecretsKeychain.legacyId(agentId: agentId, key: $0) },
                isDeleted: { store.isDeleted($0, scope: .agent(agentId)) })
        }
        for record in effectiveRecords(agentId: agentId, store: store) where record.exposeToSandbox {
            guard !isReservedEnvVar(record.key) else { continue }
            if let value = store.value(record.key, scope: record.scope) { env[record.key] = value }
        }
        return env
    }

    /// The subset of `env` whose values are secrets, for output scrubbing.
    /// Variables stay readable in tool output.
    public static func scrubValues(
        from env: [String: String], agentId: UUID?, store: CredentialStore = .current
    ) -> [String: String] {
        env.filter { key, _ in
            effectiveRecord(key, agentId: agentId, store: store)?.kind != .variable
        }
    }

    /// Names (never values) of what the agent can read when running code.
    public static func availableKeys(agentId: UUID, store: CredentialStore = .current) -> [String] {
        var keys = Set(
            effectiveRecords(agentId: agentId, store: store)
                .filter { $0.exposeToSandbox && !isReservedEnvVar($0.key) }
                .map(\.key))
        let legacy = legacyEntries(
            Dictionary(uniqueKeysWithValues: AgentSecretsKeychain.secretIDs(agentId: agentId).map { ($0, "") }),
            store: store,
            legacyId: { AgentSecretsKeychain.legacyId(agentId: agentId, key: $0) },
            isDeleted: { store.isDeleted($0, scope: .agent(agentId)) })
        keys.formUnion(legacy.keys)
        return keys.sorted()
    }

    /// Env for a sandbox plugin: the plugin's unimported legacy values, then
    /// the agent's sandbox env, then each declared key, which reaches its
    /// owning plugin even when not exposed.
    public static func sandboxPluginEnvironment(
        agentId: UUID?, pluginId: String, pluginName: String, declared: [String],
        store: CredentialStore = .current
    ) -> [String: String] {
        let legacyAgent = agentId ?? Agent.defaultId
        var base = legacyEntries(
            ToolSecretsKeychain.readOnlySecrets(for: pluginId, agentId: legacyAgent), store: store,
            legacyId: { ToolSecretsKeychain.legacyId(agentId: legacyAgent, pluginId: pluginId, key: $0) },
            isDeleted: { wasDeleted($0, agentId: agentId, store: store) })
        base.merge(sandboxEnvironment(agentId: agentId, store: store)) { _, new in new }
        return PluginCredentials.environment(
            base: base, declared: declared.filter { !isReservedEnvVar($0) }, pluginId: pluginId,
            pluginName: pluginName, agentId: agentId, store: store
        ) { name in
            agentId.map { agentId in
                [SandboxCredentials.legacyItem(name, agentId: agentId)]
            } ?? []
        }
    }
}

/// Whether a not-yet-imported legacy item exists, answered without a
/// Keychain read on the caller's thread so checks that run while views
/// render never block. An unknown item reads as absent and is looked up in
/// the background; finding it posts `.credentialsDidChange` for `key`.
final class LegacyPresenceCache: @unchecked Sendable {
    static let shared = LegacyPresenceCache()

    private let lock = NSLock()
    private var known: [String: Bool] = [:]
    private var pending: Set<String> = []

    func isPresent(
        _ legacyId: String, key: String, store: CredentialStore = .current,
        read: @escaping @Sendable () -> Bool
    ) -> Bool {
        guard CredentialResolver.mayReadLegacy(legacyId, store: store) else { return false }
        let (answer, starts) = lock.withLock { () -> (Bool?, Bool) in
            if let present = known[legacyId] { return (present, false) }
            return (nil, pending.insert(legacyId).inserted)
        }
        if let answer { return answer }
        if starts {
            Task.detached(priority: .utility) { [self] in
                let present = CredentialStore.$taskLocalStore.withValue(store) { read() }
                lock.withLock {
                    known[legacyId] = present
                    pending.remove(legacyId)
                }
                if present { store.notifyChanged(keys: [key]) }
            }
        }
        return false
    }

    func _resetForTesting() {
        lock.withLock {
            known.removeAll()
            pending.removeAll()
        }
    }
}
