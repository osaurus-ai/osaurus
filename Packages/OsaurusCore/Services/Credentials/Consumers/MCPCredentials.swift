//
//  MCPCredentials.swift
//  osaurus
//
//  MCP server secrets (env vars, headers, bearer token) resolved through the
//  unified store. `mcp.json` still lists which slots exist
//  (`secretEnvKeys`, `secretHeaderKeys`, plain `env`/`customHeaders`);
//  values come from the credential bound to each slot. OAuth tokens stay in
//  `MCPProviderKeychain`.
//

import Foundation

public enum MCPCredentials {
    // MARK: - Slots

    public static func envSlot(_ provider: MCPProvider, name: String) -> CredentialSlot {
        .mcpEnv(providerId: provider.id, providerName: provider.name, name: name)
    }

    public static func headerSlot(_ provider: MCPProvider, header: String) -> CredentialSlot {
        .mcpHeader(providerId: provider.id, providerName: provider.name, header: header)
    }

    public static func tokenSlot(_ provider: MCPProvider) -> CredentialSlot {
        .mcpToken(providerId: provider.id, providerName: provider.name)
    }

    public static func plainEnvSlot(_ provider: MCPProvider, name: String) -> CredentialSlot {
        .mcpPlain(providerId: provider.id, providerName: provider.name, kind: "env", name: name)
    }

    public static func plainHeaderSlot(_ provider: MCPProvider, header: String) -> CredentialSlot {
        .mcpPlain(providerId: provider.id, providerName: provider.name, kind: "header", name: header)
    }

    /// Every secret slot the provider declares.
    public static func secretSlots(_ provider: MCPProvider) -> [CredentialSlot] {
        var slots: [CredentialSlot] = []
        if provider.transport == .stdio {
            slots += provider.secretEnvKeys.map { envSlot(provider, name: $0) }
        } else {
            slots += provider.secretHeaderKeys.map { headerSlot(provider, header: $0) }
            if provider.authType == .bearerToken { slots.append(tokenSlot(provider)) }
        }
        return slots
    }

    // MARK: - Legacy ids

    static func legacyId(providerId: UUID, suffix: String) -> String {
        "ai.osaurus.mcp/\(providerId.uuidString).\(suffix)"
    }

    static func envLegacy(providerId id: UUID, name: String) -> CredentialResolver.LegacyItem {
        CredentialResolver.LegacyItem(legacyId(providerId: id, suffix: "env.\(name)")) {
            MCPProviderKeychain.getEnvSecret(key: name, for: id)
        }
    }

    static func headerLegacy(providerId id: UUID, header: String) -> CredentialResolver.LegacyItem {
        CredentialResolver.LegacyItem(legacyId(providerId: id, suffix: "header.\(header)")) {
            MCPProviderKeychain.getHeaderSecret(key: header, for: id)
        }
    }

    static func tokenLegacy(providerId id: UUID) -> CredentialResolver.LegacyItem {
        CredentialResolver.LegacyItem(legacyId(providerId: id, suffix: "token")) {
            MCPProviderKeychain.getToken(for: id)
        }
    }

    // MARK: - Values

    public static func envValue(_ provider: MCPProvider, name: String, agentId: UUID?) -> String? {
        CredentialResolver.resolve(
            envSlot(provider, name: name), agentId: agentId, legacy: [envLegacy(providerId: provider.id, name: name)])
    }

    public static func headerValue(_ provider: MCPProvider, header: String, agentId: UUID?) -> String? {
        CredentialResolver.resolve(
            headerSlot(provider, header: header), agentId: agentId,
            legacy: [headerLegacy(providerId: provider.id, header: header)])
    }

    public static func tokenValue(_ provider: MCPProvider, agentId: UUID?) -> String? {
        CredentialResolver.resolve(tokenSlot(provider), agentId: agentId, legacy: [tokenLegacy(providerId: provider.id)])
    }

    /// A plain env/header value replaced by an explicitly bound variable.
    static func plainOverride(_ slot: CredentialSlot, agentId: UUID?) -> String? {
        guard let key = CredentialStore.current.boundKey(for: slot.id) else { return nil }
        return CredentialResolver.value(key, agentId: agentId)
    }

    // MARK: - Writes (new store only)

    /// Save a secret for `slot` for all agents. Empty `value` removes it; the
    /// delete's tombstone keeps the legacy fallback off. The binding is pinned
    /// so a later server rename (which changes the suggested key) keeps the
    /// value. With `separateOnConflict`, a first save whose key already holds
    /// a different value goes to `<SERVER>_<KEY>` instead (installers/imports).
    @discardableResult
    public static func save(
        _ value: String, slot: CredentialSlot, separateOnConflict: Bool = false
    ) -> CredentialWriteOutcome {
        let store = CredentialStore.current
        if value.isEmpty {
            return store.delete(slot.effectiveKey(in: store), scope: .global)
        }
        return store.save(
            value, for: slot, owner: slot.consumer, origin: .mcp, kind: .secret,
            separateOnConflict: separateOnConflict, pin: true
        ).outcome
    }

    /// Removes this provider's slot bindings. Credentials are kept.
    static func forgetBindings(providerId: UUID, store: CredentialStore = .current) {
        let prefix = "mcp:\(providerId.uuidString.lowercased()):"
        CredentialResolver.forget(slots: store.allBindings().keys.filter { $0.hasPrefix(prefix) }, store: store)
    }

    @discardableResult
    public static func saveEnv(
        _ value: String, provider: MCPProvider, name: String, separateOnConflict: Bool = false
    ) -> Bool {
        save(value, slot: envSlot(provider, name: name), separateOnConflict: separateOnConflict).isSuccess
    }

    @discardableResult
    public static func saveHeader(
        _ value: String, provider: MCPProvider, header: String, separateOnConflict: Bool = false
    ) -> Bool {
        save(value, slot: headerSlot(provider, header: header), separateOnConflict: separateOnConflict).isSuccess
    }

    /// Bearer-token presence for all agents, from the index plus the
    /// not-yet-imported legacy item.
    static func tokenAvailability(_ provider: MCPProvider) -> SecretAvailability {
        let store = CredentialStore.current
        let key = tokenSlot(provider).effectiveKey(in: store)
        if store.hasValue(key, scope: .global) { return store.availability(key, scope: .global) }
        let legacy = legacyId(providerId: provider.id, suffix: "token")
        guard CredentialResolver.mayUseLegacy(legacy, for: key, agentId: nil, store: store) else { return .absent }
        return MCPProviderKeychain.tokenAvailability(for: provider.id)
    }

    public static func saveToken(_ value: String, provider: MCPProvider) -> Bool {
        save(value, slot: tokenSlot(provider)).isSuccess
    }

    // MARK: - Per-agent variants

    /// Keys this provider reads, after bindings.
    static func boundKeys(_ provider: MCPProvider, store: CredentialStore = .current) -> [String] {
        var keys = secretSlots(provider).map { $0.effectiveKey(in: store) }
        for name in provider.env.keys where !provider.secretEnvKeys.contains(name) {
            if let key = store.boundKey(for: plainEnvSlot(provider, name: name).id) { keys.append(key) }
        }
        for header in provider.customHeaders.keys where !provider.secretHeaderKeys.contains(header) {
            if let key = store.boundKey(for: plainHeaderSlot(provider, header: header).id) { keys.append(key) }
        }
        return keys
    }

    /// True when `agentId` has its own value for any key the provider reads,
    /// meaning its calls need a connection built with that agent's values.
    public static func agentHasOverride(_ provider: MCPProvider, agentId: UUID?) -> Bool {
        guard let agentId else { return false }
        if signInSession(provider, agentId: agentId) != signInSession(provider, agentId: nil) { return true }
        let store = CredentialStore.current
        return boundKeys(provider).contains { store.hasValue($0, scope: .agent(agentId)) }
    }

    /// The sign-in session an OAuth server's calls use for `agentId`: its
    /// own session when assigned, else the server's default. nil when the
    /// server has no sessions (its one sign-in) or is not OAuth.
    static func signInSession(_ provider: MCPProvider, agentId: UUID?) -> SignInSession? {
        guard provider.authType == .oauth else { return nil }
        return SignInSessionResolver.session(for: .mcp(provider.id), agentId: agentId)
    }

    /// Stable fingerprint of the credential values a connection was built
    /// with, so a changed value rebuilds the connection. Never logged.
    static func fingerprint(_ provider: MCPProvider, agentId: UUID?) -> String {
        var hasher = Hasher()
        hasher.combine(signInSession(provider, agentId: agentId)?.id)
        for key in boundKeys(provider).sorted() {
            hasher.combine(key)
            hasher.combine(CredentialResolver.value(key, agentId: agentId) ?? "")
        }
        return String(hasher.finalize())
    }
}
