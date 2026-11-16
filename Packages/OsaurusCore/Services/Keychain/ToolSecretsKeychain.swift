//
//  ToolSecretsKeychain.swift
//  osaurus
//
//  Keychain storage for plugin config and runtime state that is not a
//  declared secret (`tunnel_url`, undeclared `config_set` keys, Claude
//  plugin `userConfig`). Declared plugin secrets live in the Keys store
//  (`PluginCredentials`); their old items here are read only as its legacy
//  fallback, through the `readOnly*` functions.
//

import Foundation
import Security

/// Agent-scoped plugin config: account format is `"{agentId}.{pluginId}.{key}"`.
public enum ToolSecretsKeychain {
    private static let service = "ai.osaurus.tools"
    private static let testStoreLock = NSLock()
    private nonisolated(unsafe) static var testStore: [String: String] = [:]

    // MARK: - Presence memoization

    // `hasSecret` can run on view-body call paths, and each call is a
    // full `SecItemCopyMatching` round-trip through securityd
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
        if KeychainQueryHelpers.usesInMemoryKeychainStoreForTests {
            testStoreLock.withLock { testStore[account] = value }
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
        if KeychainQueryHelpers.usesInMemoryKeychainStoreForTests {
            if let value = testStoreLock.withLock({ testStore[account] }) { return value }
            return preScopingValue(id: id, pluginId: pluginId, agentId: agentId)
        }
        if KeychainQueryHelpers.disablesKeychainForProcess { return nil }
        if let data = Keychain.read(service: service, account: account),
            let value = String(data: data, encoding: .utf8) {
            return value
        }
        return preScopingValue(id: id, pluginId: pluginId, agentId: agentId)
    }

    /// Fallback for values saved before agent scoping as `"{pluginId}.{key}"`,
    /// read for the Default agent only. The old item is never copied,
    /// rewritten, or deleted by a read, so an older build keeps working.
    private static func preScopingValue(id: String, pluginId: String, agentId: UUID) -> String? {
        guard agentId == Agent.defaultId else { return nil }
        let legacyAccount = "\(pluginId).\(id)"
        if KeychainQueryHelpers.usesInMemoryKeychainStoreForTests {
            return testStoreLock.withLock { testStore[legacyAccount] }
        }
        guard case .found(let data) = Keychain.readItem(service: service, account: legacyAccount) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public static func hasSecret(id: String, for pluginId: String, agentId: UUID) -> Bool {
        let account = agentAccount(agentId: agentId, pluginId: pluginId, key: id)
        if KeychainQueryHelpers.usesInMemoryKeychainStoreForTests
            || KeychainQueryHelpers.disablesKeychainForProcess
        {
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
            // A value saved before agent scoping still counts.
            let present = preScopingValue(id: id, pluginId: pluginId, agentId: agentId) != nil
            notePresence(present, account: account)
            return present
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
        // pre-scoping `"{pluginId}.{key}"` twin; otherwise the read fallback
        // would bring back a value the user deleted.
        let legacyAccount = agentId == Agent.defaultId ? "\(pluginId).\(id)" : nil
        if KeychainQueryHelpers.usesInMemoryKeychainStoreForTests {
            testStoreLock.withLock {
                _ = testStore.removeValue(forKey: account)
                if let legacyAccount { _ = testStore.removeValue(forKey: legacyAccount) }
            }
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

    /// Per-agent config merged on top of the `Agent.defaultId` namespace,
    /// which Plugins-tab writes used as the value for every agent.
    public static func resolvedSecretsWithDefaults(pluginId: String, agentId: UUID) -> [String: String] {
        var merged = getAllSecrets(for: pluginId, agentId: Agent.defaultId)
        guard agentId != Agent.defaultId else { return merged }
        merged.merge(getAllSecrets(for: pluginId, agentId: agentId)) { _, own in own }
        return merged
    }

    /// One key under the same rule: the agent's namespace, then the
    /// `Agent.defaultId` namespace.
    public static func resolvedSecret(id: String, for pluginId: String, agentId: UUID) -> String? {
        if let exact = getSecret(id: id, for: pluginId, agentId: agentId) {
            return exact
        }
        guard agentId != Agent.defaultId else { return nil }
        return getSecret(id: id, for: pluginId, agentId: Agent.defaultId)
    }

    // MARK: - Legacy (read-only) access for CredentialStore

    /// `<service>/<account>` id the credential migration tracks for an item.
    static func legacyId(agentId: UUID, pluginId: String, key: String) -> String {
        "\(service)/\(agentAccount(agentId: agentId, pluginId: pluginId, key: key))"
    }

    /// Every account name under the tools service, for the one-way import.
    static func legacyAccountNames() -> [String] {
        legacyAccountListing().names
    }

    /// Account names plus whether the listing is authoritative (false when
    /// the Keychain is locked or the query failed).
    static func legacyAccountListing() -> (names: [String], isDefinitive: Bool) {
        if KeychainQueryHelpers.usesInMemoryKeychainStoreForTests || KeychainQueryHelpers.disablesKeychainForProcess {
            return (fetchAllItems(attributesOnly: true).compactMap { $0[kSecAttrAccount as String] as? String }, true)
        }
        let outcome = Keychain.fetchAllItems(service: service, returnData: false)
        return (outcome.items.compactMap { $0[kSecAttrAccount as String] as? String }, outcome.isDefinitive)
    }

    /// Pure read of one item: the agent-scoped account, then (for the
    /// Default agent) the pre-agent-scoping `"{pluginId}.{key}"` account.
    /// Unlike `getSecret` it never migrates, writes, or deletes anything.
    static func readOnlySecret(id: String, for pluginId: String, agentId: UUID) -> String? {
        var accounts = [agentAccount(agentId: agentId, pluginId: pluginId, key: id)]
        if agentId == Agent.defaultId { accounts.append("\(pluginId).\(id)") }
        for account in accounts {
            if KeychainQueryHelpers.usesInMemoryKeychainStoreForTests {
                if let value = testStoreLock.withLock({ testStore[account] }) { return value }
                continue
            }
            if KeychainQueryHelpers.disablesKeychainForProcess { return nil }
            if case .found(let data) = Keychain.readItem(service: service, account: account),
                let value = String(data: data, encoding: .utf8)
            {
                return value
            }
        }
        return nil
    }

    /// Pure read of every secret `agentId` saved for `pluginId`.
    static func readOnlySecrets(for pluginId: String, agentId: UUID) -> [String: String] {
        let accountPrefix = agentAccountPrefix(agentId: agentId, pluginId: pluginId)
        var secrets: [String: String] = [:]
        for account in legacyAccountNames() where account.hasPrefix(accountPrefix) {
            let secretId = String(account.dropFirst(accountPrefix.count))
            if let value = readOnlySecret(id: secretId, for: pluginId, agentId: agentId) {
                secrets[secretId] = value
            }
        }
        return secrets
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
        if KeychainQueryHelpers.usesInMemoryKeychainStoreForTests {
            return testStoreLock.withLock {
                testStore.map { account, value in
                    var item: [String: Any] = [kSecAttrAccount as String: account]
                    if !attributesOnly {
                        item[kSecValueData as String] = Data(value.utf8)
                    }
                    return item
                }
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
        testStoreLock.withLock { testStore[account] = value }
    }

    static func _testRemoveRawAccount(_ account: String) {
        testStoreLock.withLock { _ = testStore.removeValue(forKey: account) }
    }

    /// Raw account lookup in the in-memory test store. Test-only.
    static func _testRawAccountValue(_ account: String) -> String? {
        testStoreLock.withLock { testStore[account] }
    }

    private static func deleteAllMatchingPrefix(_ prefix: String) {
        // Bulk deletes are rare (plugin uninstall, agent deletion); dropping
        // the whole presence cache is simpler than prefix-matching it.
        clearPresenceCache()
        if KeychainQueryHelpers.usesInMemoryKeychainStoreForTests {
            testStoreLock.withLock {
                let matchingAccounts = testStore.keys.filter { $0.hasPrefix(prefix) }
                for account in matchingAccounts {
                    testStore.removeValue(forKey: account)
                }
            }
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
