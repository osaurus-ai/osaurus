//
//  ToolSecretsKeychain.swift
//  osaurus
//
//  Secure Keychain storage for plugin secrets (API keys, tokens, etc.).
//

import Foundation
import Security

/// Keychain wrapper for secure plugin secret storage.
/// All config is agent-scoped: account format is `"{agentId}.{pluginId}.{key}"`.
public enum ToolSecretsKeychain {
    private static let service = "ai.osaurus.tools"

    // MARK: - In-Memory Store (tests)

    /// Lock-guarded mutable storage scoped to one task tree. A process-global
    /// dictionary would let parallel test cases observe or delete one
    /// another's credentials, so tests must bind a fresh store explicitly.
    fileprivate final class InMemorySecretStore: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [String: String] = [:]

        func get(_ account: String) -> String? {
            lock.lock()
            defer { lock.unlock() }
            return storage[account]
        }

        func set(_ account: String, _ value: String?) {
            lock.lock()
            defer { lock.unlock() }
            storage[account] = value
        }

        func migrateValue(from legacyAccount: String, to canonicalAccount: String) -> String? {
            lock.lock()
            defer { lock.unlock() }
            if let canonicalValue = storage[canonicalAccount] {
                return canonicalValue
            }
            guard let legacyValue = storage[legacyAccount] else { return nil }
            storage[canonicalAccount] = legacyValue
            storage.removeValue(forKey: legacyAccount)
            return legacyValue
        }

        func accounts() -> [String] {
            lock.lock()
            defer { lock.unlock() }
            return Array(storage.keys)
        }

        func removeAll(matching predicate: (String) -> Bool) {
            lock.lock()
            defer { lock.unlock() }
            storage = storage.filter { !predicate($0.key) }
        }
    }

    /// Test persistence is task-local only. There is deliberately no
    /// process-wide fallback: an unbound recognized test-host call must reach
    /// the keychain-disabled/no-op path instead of sharing secrets or touching
    /// the user's login Keychain.
    @TaskLocal private static var taskLocalStore: InMemorySecretStore?

    /// Opaque capability for the small number of production paths that must
    /// cross an intentional `Task.detached` boundary during a test. Detached
    /// tasks never inherit task locals, so callers must capture and rebind the
    /// exact store rather than falling back to process-global test state.
    struct InMemoryStoreContext: @unchecked Sendable {
        fileprivate let store: InMemorySecretStore
    }

    private static var activeInMemoryStore: InMemorySecretStore? {
        taskLocalStore
    }

    static func _withInMemoryStoreForTesting<T>(
        _ body: () throws -> T
    ) rethrows -> T {
        try $taskLocalStore.withValue(InMemorySecretStore()) {
            try body()
        }
    }

    /// Async-body variant for tests that exercise asynchronous plugin and
    /// lifecycle paths. Child tasks inherit the bound store; detached work is
    /// intentionally unbound and therefore cannot bypass process isolation.
    static func _withInMemoryStoreForTesting<T>(
        _ body: @Sendable () async throws -> T
    ) async rethrows -> T {
        try await $taskLocalStore.withValue(InMemorySecretStore()) {
            try await body()
        }
    }

    static func _captureInMemoryStoreContextForTesting() -> InMemoryStoreContext? {
        guard let store = taskLocalStore else { return nil }
        return InMemoryStoreContext(store: store)
    }

    static func _withInMemoryStoreContextForTesting<T>(
        _ context: InMemoryStoreContext?,
        _ body: () throws -> T
    ) rethrows -> T {
        guard let context else { return try body() }
        return try $taskLocalStore.withValue(context.store) {
            try body()
        }
    }

    // MARK: - Presence memoization

    // `hasSecret` runs on view-body call paths (e.g. the chat context
    // estimate resolving Discord auto-destinations via `hasBotToken`), and
    // each call is a full `SecItemCopyMatching` round-trip through securityd
    // including item decryption — observed as multi-second main-thread hangs
    // when the daemon is slow. Presence only changes through this type's own
    // save/delete paths, so it's cached per account and updated there.
    // External edits via Keychain Access are not tracked; a stale presence
    // bit there costs one failed plugin call, not a hang.
    private static let presenceLock = NSLock()
    private nonisolated(unsafe) static var presenceCache: [String: Bool] = [:]

    private static func cachedPresence(_ account: String, compute: () -> Bool) -> Bool {
        presenceLock.lock()
        if let cached = presenceCache[account] {
            presenceLock.unlock()
            return cached
        }
        presenceLock.unlock()
        let result = compute()
        presenceLock.lock()
        presenceCache[account] = result
        presenceLock.unlock()
        return result
    }

    private static func notePresence(_ present: Bool, account: String) {
        presenceLock.lock()
        presenceCache[account] = present
        presenceLock.unlock()
    }

    private static func clearPresenceCache() {
        presenceLock.lock()
        presenceCache.removeAll(keepingCapacity: true)
        presenceLock.unlock()
    }

    // MARK: - Agent-Scoped Secret Management

    @discardableResult
    public static func saveSecret(_ value: String, id: String, for pluginId: String, agentId: UUID) -> Bool {
        saveSecretOutcome(value, id: id, for: pluginId, agentId: agentId).isSuccess
    }

    /// Typed variant of `saveSecret` so callers can surface the exact
    /// Keychain failure (locked vs. access denied vs. OSStatus) instead of a
    /// generic "storage was unavailable".
    static func saveSecretOutcome(
        _ value: String, id: String, for pluginId: String, agentId: UUID
    ) -> KeychainMutationOutcome {
        let account = agentAccount(agentId: agentId, pluginId: pluginId, key: id)
        if let store = activeInMemoryStore {
            store.set(account, value)
            return .success
        }
        guard let valueData = value.data(using: .utf8) else { return .failure(errSecParam) }
        if KeychainQueryHelpers.disablesKeychainForProcess { return .disabled }
        let outcome = Keychain.writeItem(service: service, account: account, data: valueData)
        if outcome.isSuccess { notePresence(true, account: account) }
        return outcome
    }

    public static func getSecret(id: String, for pluginId: String, agentId: UUID) -> String? {
        let account = agentAccount(agentId: agentId, pluginId: pluginId, key: id)
        if let store = activeInMemoryStore {
            if let value = store.get(account) { return value }
            return migrateLegacySecretIfPresent(id: id, pluginId: pluginId, agentId: agentId)
        }
        if KeychainQueryHelpers.disablesKeychainForProcess { return nil }
        if let data = Keychain.read(service: service, account: account),
            let value = String(data: data, encoding: .utf8) {
            return value
        }
        return migrateLegacySecretIfPresent(id: id, pluginId: pluginId, agentId: agentId)
    }

    /// Read-through migration for pre-agent-scoping secrets stored as
    /// `"{pluginId}.{key}"`. Uninstall has cleanup code for that format but
    /// nothing ever *read* it after the agent-scoping migration, so a user
    /// upgrading from an old build silently lost those credentials. Only the
    /// default-agent namespace falls back (per-agent reads already fall back
    /// to `Agent.defaultId` via `resolvedSecret`, so every resolution path
    /// benefits). On a hit the value is copied to the canonical account, and
    /// the legacy item is deleted only after the canonical copy reads back —
    /// an interrupted migration can never lose the secret.
    private static func migrateLegacySecretIfPresent(
        id: String, pluginId: String, agentId: UUID
    ) -> String? {
        guard agentId == Agent.defaultId else { return nil }
        let legacyAccount = "\(pluginId).\(id)"
        let canonicalAccount = agentAccount(agentId: agentId, pluginId: pluginId, key: id)

        if let store = activeInMemoryStore {
            return store.migrateValue(from: legacyAccount, to: canonicalAccount)
        }
        if KeychainQueryHelpers.disablesKeychainForProcess { return nil }
        guard case .found(let data) = Keychain.readItem(service: service, account: legacyAccount),
            let value = String(data: data, encoding: .utf8)
        else { return nil }
        if Keychain.write(service: service, account: canonicalAccount, data: data),
            Keychain.read(service: service, account: canonicalAccount) == data {
            Keychain.delete(service: service, account: legacyAccount)
        }
        return value
    }

    public static func hasSecret(id: String, for pluginId: String, agentId: UUID) -> Bool {
        let account = agentAccount(agentId: agentId, pluginId: pluginId, key: id)
        if activeInMemoryStore != nil || KeychainQueryHelpers.disablesKeychainForProcess {
            return getSecret(id: id, for: pluginId, agentId: agentId) != nil
        }
        presenceLock.lock()
        if let cached = presenceCache[account] {
            presenceLock.unlock()
            return cached
        }
        presenceLock.unlock()

        let outcome = Keychain.readItem(service: service, account: account)
        switch outcome {
        case .found:
            notePresence(true, account: account)
            return true
        case .notFound:
            // The legacy read-through migration can still surface the secret
            // under the pre-agent-scoping account.
            let migrated =
                migrateLegacySecretIfPresent(id: id, pluginId: pluginId, agentId: agentId) != nil
            notePresence(migrated, account: account)
            return migrated
        default:
            // Transient (locked keychain, securityd unavailable) or denied:
            // report absent for now but never latch it in the cache.
            return false
        }
    }

    @discardableResult
    public static func deleteSecret(id: String, for pluginId: String, agentId: UUID) -> Bool {
        let account = agentAccount(agentId: agentId, pluginId: pluginId, key: id)
        // Deleting from the default-agent namespace also removes any
        // pre-migration `"{pluginId}.{key}"` twin — otherwise the legacy
        // read-through fallback would resurrect a secret the user deleted.
        let legacyAccount = agentId == Agent.defaultId ? "\(pluginId).\(id)" : nil
        if let store = activeInMemoryStore {
            store.set(account, nil)
            if let legacyAccount { store.set(legacyAccount, nil) }
            return true
        }
        if KeychainQueryHelpers.disablesKeychainForProcess { return true }
        let deleted = Keychain.delete(service: service, account: account)
        if let legacyAccount {
            Keychain.delete(service: service, account: legacyAccount)
        }
        notePresence(false, account: account)
        return deleted
    }

    public static func deleteAllSecrets(for pluginId: String, agentId: UUID) {
        let accountPrefix = agentAccountPrefix(agentId: agentId, pluginId: pluginId)
        deleteAllMatchingPrefix(accountPrefix)
    }

    /// Delete all agent-scoped secrets for a plugin across every agent.
    public static func deleteAllSecretsAllAgents(for pluginId: String) {
        clearPresenceCache()
        if let store = activeInMemoryStore {
            let suffix = ".\(pluginId)."
            store.removeAll { $0.contains(suffix) }
            return
        }
        if KeychainQueryHelpers.disablesKeychainForProcess { return }
        let allItems = fetchAllItems(attributesOnly: true)
        let suffix = ".\(pluginId)."
        for item in allItems {
            guard let account = item[kSecAttrAccount as String] as? String,
                account.contains(suffix)
            else { continue }
            Keychain.delete(service: service, account: account)
        }
    }

    /// Delete every per-agent secret across all plugins for the given
    /// `agentId`. Called from `AgentManager.delete(id:)` so deleting an
    /// agent does not leave stale `bot_token` / OAuth credentials /
    /// per-agent webhook URLs accumulating in Keychain Access. Sweeps
    /// any account whose prefix is `"{agentId}."`.
    public static func deleteAllSecrets(forAgent agentId: UUID) {
        deleteAllMatchingPrefix("\(agentId.uuidString).")
    }

    public static func getAllSecrets(for pluginId: String, agentId: UUID) -> [String: String] {
        let accountPrefix = agentAccountPrefix(agentId: agentId, pluginId: pluginId)

        let allItems = fetchAllItems(attributesOnly: true)
        var secrets: [String: String] = [:]
        for item in allItems {
            guard let account = item[kSecAttrAccount as String] as? String,
                account.hasPrefix(accountPrefix)
            else { continue }
            let secretId = String(account.dropFirst(accountPrefix.count))
            if let value = getSecret(id: secretId, for: pluginId, agentId: agentId) {
                secrets[secretId] = value
            }
        }

        return secrets
    }

    /// Per-agent secrets merged on top of `Agent.defaultId` (Plugins-tab
    /// writes act as global defaults; Agents-tab writes override per-key).
    public static func resolvedSecretsWithDefaults(pluginId: String, agentId: UUID) -> [String: String] {
        resolvedSecretsMerging(pluginId: pluginId, primary: agentId, defaults: Agent.defaultId)
    }

    /// THE single per-key resolution policy: exact agent namespace first,
    /// then the `Agent.defaultId` namespace as the global-default fallback
    /// (Plugins-tab writes land there). This is the per-key equivalent of
    /// `resolvedSecretsWithDefaults` and must be used by every read path
    /// that feeds plugins — `config_get`, initial config delivery, and
    /// required-secret checks — so they can't disagree with tool payload
    /// injection about whether a key is configured.
    public static func resolvedSecret(id: String, for pluginId: String, agentId: UUID) -> String? {
        if let exact = getSecret(id: id, for: pluginId, agentId: agentId) {
            return exact
        }
        guard agentId != Agent.defaultId else { return nil }
        return getSecret(id: id, for: pluginId, agentId: Agent.defaultId)
    }

    /// `resolvedSecret` presence check (exact agent, then default-agent
    /// fallback).
    public static func hasResolvedSecret(id: String, for pluginId: String, agentId: UUID) -> Bool {
        resolvedSecret(id: id, for: pluginId, agentId: agentId) != nil
    }

    /// Two-id merge primitive: `primary` agent's secrets overlaid on `defaults`.
    public static func resolvedSecretsMerging(pluginId: String, primary: UUID, defaults: UUID) -> [String: String] {
        let defaultDict = getAllSecrets(for: pluginId, agentId: defaults)
        if primary == defaults { return defaultDict }
        let primaryDict = getAllSecrets(for: pluginId, agentId: primary)
        var merged = defaultDict
        for (k, v) in primaryDict { merged[k] = v }
        return merged
    }

    /// Required-secret check under the shared resolution policy: a key
    /// satisfied by a Plugins-tab (default-agent) write counts as
    /// configured for every agent, matching what tool payload injection
    /// actually delivers via `resolvedSecretsWithDefaults`.
    public static func hasAllRequiredSecrets(specs: [PluginManifest.SecretSpec], for pluginId: String, agentId: UUID)
        -> Bool
    {
        for spec in specs where spec.required {
            if !hasResolvedSecret(id: spec.id, for: pluginId, agentId: agentId) {
                return false
            }
        }
        return true
    }

    public static func getMissingRequiredSecrets(
        specs: [PluginManifest.SecretSpec],
        for pluginId: String,
        agentId: UUID
    ) -> [PluginManifest.SecretSpec] {
        return specs.filter { spec in
            spec.required && !hasResolvedSecret(id: spec.id, for: pluginId, agentId: agentId)
        }
    }

    // MARK: - Legacy Cleanup (non-agent-scoped entries)

    /// Delete all legacy (non-agent-scoped) entries matching `"{pluginId}.*"`.
    /// Used during plugin uninstall to clean up any remaining pre-migration data.
    public static func deleteAllSecrets(for pluginId: String) {
        deleteAllMatchingPrefix("\(pluginId).")
    }

    // MARK: - Internal Helpers

    private static func agentAccount(agentId: UUID, pluginId: String, key: String) -> String {
        "\(agentId.uuidString).\(pluginId).\(key)"
    }

    private static func agentAccountPrefix(agentId: UUID, pluginId: String) -> String {
        "\(agentId.uuidString).\(pluginId)."
    }

    /// UUID pattern: 8-4-4-4-12 hex at the start of the account string.
    private static func isAgentScopedAccount(_ account: String) -> Bool {
        let uuidLength = 36  // "XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX"
        guard account.count > uuidLength,
            account[account.index(account.startIndex, offsetBy: uuidLength)] == "."
        else { return false }
        let prefix = String(account.prefix(uuidLength))
        return UUID(uuidString: prefix) != nil
    }

    private static func fetchAllItems(attributesOnly: Bool) -> [[String: Any]] {
        if let store = activeInMemoryStore {
            return store.accounts().compactMap { account in
                guard let value = store.get(account) else { return nil }
                var item: [String: Any] = [kSecAttrAccount as String: account]
                if !attributesOnly {
                    item[kSecValueData as String] = Data(value.utf8)
                }
                return item
            }
        }
        if KeychainQueryHelpers.disablesKeychainForProcess { return [] }
        return Keychain.fetchAll(service: service, returnData: !attributesOnly)
    }

    // MARK: - Test seams

    /// Seed a raw account (e.g. a pre-agent-scoping `"{pluginId}.{key}"`
    /// entry) into the in-memory test store. Test-only: production code has
    /// no API that writes the legacy format anymore.
    static func _testSeedRawAccount(_ account: String, value: String) {
        activeInMemoryStore?.set(account, value)
    }

    /// Raw account lookup in the in-memory test store. Test-only.
    static func _testRawAccountValue(_ account: String) -> String? {
        activeInMemoryStore?.get(account)
    }

    private static func deleteAllMatchingPrefix(_ prefix: String) {
        // Bulk deletes are rare (plugin uninstall, agent deletion); dropping
        // the whole presence cache is simpler than prefix-matching it.
        clearPresenceCache()
        if let store = activeInMemoryStore {
            store.removeAll { $0.hasPrefix(prefix) }
            return
        }
        if KeychainQueryHelpers.disablesKeychainForProcess { return }
        let allItems = fetchAllItems(attributesOnly: true)
        for item in allItems {
            guard let account = item[kSecAttrAccount as String] as? String,
                account.hasPrefix(prefix)
            else { continue }
            Keychain.delete(service: service, account: account)
        }
    }
}
