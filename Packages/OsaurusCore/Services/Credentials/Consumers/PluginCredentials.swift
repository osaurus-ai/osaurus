//
//  PluginCredentials.swift
//  osaurus
//
//  Plugin secrets declared in a manifest (`secrets: [SecretSpec]`) or by a
//  sandbox plugin (`secrets: [String]`) live in the unified store. Anything
//  else a plugin saves through `config_set` (non-secret config, runtime
//  state like `tunnel_url`) stays in `ToolSecretsKeychain`.
//

import Foundation

public enum PluginCredentials {
    public static func slot(pluginId: String, pluginName: String? = nil, specId: String, required: Bool = true)
        -> CredentialSlot
    {
        CredentialSlot.plugin(
            pluginId: pluginId, pluginName: pluginName ?? pluginId, specId: specId, required: required)
    }

    // MARK: - Declared secret ids

    private static let declaredLock = NSLock()
    nonisolated(unsafe) private static var declared: [String: Set<String>] = [:]

    /// Recorded when a plugin's manifest is known, so `config_set` can route
    /// declared secrets to the unified store from any thread.
    static func registerDeclaredSecrets(pluginId: String, ids: [String]) {
        declaredLock.withLock { declared[pluginId] = Set(ids) }
    }

    static func isDeclaredSecret(pluginId: String, key: String) -> Bool {
        declaredLock.withLock { declared[pluginId]?.contains(key) ?? false }
    }

    /// `config_get` read. A declared secret resolves through the unified
    /// store (with the legacy fallback); any other key is plugin config or
    /// state and is read from the plugin's own store as before.
    static func configValue(pluginId: String, key: String, agentId: UUID, store: CredentialStore = .current)
        -> String?
    {
        guard isDeclaredSecret(pluginId: pluginId, key: key) else {
            return ToolSecretsKeychain.resolvedSecret(id: key, for: pluginId, agentId: agentId)
        }
        return value(pluginId: pluginId, specId: key, agentId: agentId, store: store)
    }

    /// `config_set` / `config_delete` for a declared secret: the calling
    /// agent's own value in the unified store. Returns false for any other
    /// key, which the caller keeps in the plugin's config store.
    static func configWrite(
        pluginId: String, key: String, value: String?, agentId: UUID, store: CredentialStore = .current
    ) -> Bool {
        guard isDeclaredSecret(pluginId: pluginId, key: key) else { return false }
        if let value, !value.isEmpty {
            save(value, pluginId: pluginId, specId: key, agentId: agentId, store: store)
        } else {
            delete(pluginId: pluginId, specId: key, agentId: agentId, store: store)
        }
        return true
    }

    /// Value for `specId` as `agentId` sees it (agent, then global, then
    /// the not-yet-imported legacy plugin secret, then `extraLegacy`).
    public static func value(
        pluginId: String, specId: String, agentId: UUID?, store: CredentialStore = .current,
        extraLegacy: [CredentialResolver.LegacyItem] = []
    ) -> String? {
        CredentialResolver.resolve(
            slot(pluginId: pluginId, specId: specId), agentId: agentId,
            legacy: legacyItems(pluginId: pluginId, specId: specId, agentId: agentId) + extraLegacy, store: store)
    }

    public static func isSatisfied(
        pluginId: String, specId: String, agentId: UUID?, store: CredentialStore = .current
    ) -> Bool {
        CredentialResolver.isSatisfied(
            slot(pluginId: pluginId, specId: specId), agentId: agentId,
            legacy: legacyItems(pluginId: pluginId, specId: specId, agentId: agentId), store: store)
    }

    /// Save `value` for `specId`. `agentId == nil` saves for all agents.
    @discardableResult
    public static func save(
        _ value: String, pluginId: String, specId: String, agentId: UUID?, store: CredentialStore = .current
    ) -> CredentialWriteOutcome {
        let key = slot(pluginId: pluginId, specId: specId).effectiveKey(in: store)
        return store.save(key, scope: agentId.map { .agent($0) } ?? .global, value: value, origin: .plugin)
    }

    /// Remove the value for `specId` in one scope; the delete's tombstone
    /// keeps the legacy fallback from bringing it back.
    @discardableResult
    public static func delete(
        pluginId: String, specId: String, agentId: UUID?, store: CredentialStore = .current
    ) -> CredentialWriteOutcome {
        let key = slot(pluginId: pluginId, specId: specId).effectiveKey(in: store)
        return store.delete(key, scope: agentId.map { .agent($0) } ?? .global)
    }

    /// Legacy items under the old per-key rule: the exact agent, then the
    /// Default agent namespace that acted as "global".
    static func legacyItems(pluginId: String, specId: String, agentId: UUID?) -> [CredentialResolver.LegacyItem] {
        var agents = [Agent.defaultId]
        if let agentId, agentId != Agent.defaultId { agents.insert(agentId, at: 0) }
        return agents.map { agent in
            CredentialResolver.LegacyItem(ToolSecretsKeychain.legacyId(agentId: agent, pluginId: pluginId, key: specId)) {
                ToolSecretsKeychain.readOnlySecret(id: specId, for: pluginId, agentId: agent)
            }
        }
    }

    /// Every declared secret for a manifest, resolved for `agentId`.
    public static func resolvedSecrets(
        specs: [PluginManifest.SecretSpec], pluginId: String, agentId: UUID?, store: CredentialStore = .current
    ) -> [String: String] {
        environment(base: [:], declared: specs.map(\.id), pluginId: pluginId, agentId: agentId, store: store)
    }

    /// What a plugin sees: `base` (its config, or a sandbox plugin's env)
    /// underneath, each declared secret on top.
    static func environment(
        base: [String: String], declared: [String], pluginId: String, pluginName: String? = nil, agentId: UUID?,
        store: CredentialStore = .current,
        extraLegacy: (String) -> [CredentialResolver.LegacyItem] = { _ in [] }
    ) -> [String: String] {
        var env = base
        for name in declared {
            if let value = value(
                pluginId: pluginId, specId: name, agentId: agentId, store: store, extraLegacy: extraLegacy(name))
            {
                env[name] = value
            }
        }
        return env
    }

    public static func missingRequired(
        specs: [PluginManifest.SecretSpec], pluginId: String, agentId: UUID?, store: CredentialStore = .current
    ) -> [PluginManifest.SecretSpec] {
        specs.filter { $0.required && !isSatisfied(pluginId: pluginId, specId: $0.id, agentId: agentId, store: store) }
    }
}
