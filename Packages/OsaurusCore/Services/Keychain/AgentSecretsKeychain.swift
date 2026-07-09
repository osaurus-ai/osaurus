//
//  AgentSecretsKeychain.swift
//  osaurus
//
//  Secure Keychain storage for agent-level secrets (API keys, tokens, etc.).
//  Unlike ToolSecretsKeychain which is plugin-scoped, this stores secrets
//  per-agent only, making them accessible to any sandbox plugin.
//

import Foundation

/// Keychain wrapper for agent-scoped secret storage.
/// Account format: `"{agentId}.{key}"` — no plugin scoping.
public enum AgentSecretsKeychain {
    private static let service = "ai.osaurus.agent-secrets"

    // MARK: - In-Memory Store (tests + hermetic harnesses)

    /// Lock-guarded mutable dictionary usable as a `@TaskLocal` value.
    final class InMemorySecretStore: @unchecked Sendable {
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

        func accounts() -> [String] {
            lock.lock()
            defer { lock.unlock() }
            return Array(storage.keys)
        }

        func removeAll(prefix: String) {
            lock.lock()
            defer { lock.unlock() }
            storage = storage.filter { !$0.key.hasPrefix(prefix) }
        }
    }

    /// In-memory backend, active in two situations:
    ///
    ///  1. Scoped (tests): `_withInMemoryStoreForTesting` binds a fresh
    ///     TASK-LOCAL store for the closure's task tree. Task-local (not
    ///     process-global) because parallel test suites each bind their own
    ///     store — a shared global raced and wiped secrets mid-test.
    ///  2. Whole-process: `OSAURUS_AGENT_SECRETS_IN_MEMORY=1` (set by the
    ///     eval CLI). The harness runs Keychain-free
    ///     (`OSAURUS_DISABLE_KEYCHAIN_FOR_TESTS=1` — legacy-item ACL prompts
    ///     hang headless runs), but the sandbox secrets pipeline
    ///     (`sandbox_secret_set` → exec env injection → output scrubbing)
    ///     is a scored surface that needs a WORKING store. The pipeline
    ///     logic is exercised for real; only the persistence medium
    ///     changes, and the user's login Keychain stays untouched.
    ///
    /// The in-memory store is checked BEFORE the Keychain-free no-op gate,
    /// so both env vars together mean "no login Keychain, memory instead".
    @TaskLocal private static var taskLocalStore: InMemorySecretStore?

    private static let processStore: InMemorySecretStore? =
        ProcessInfo.processInfo.environment["OSAURUS_AGENT_SECRETS_IN_MEMORY"] == "1"
        ? InMemorySecretStore() : nil

    private static var activeInMemoryStore: InMemorySecretStore? {
        taskLocalStore ?? processStore
    }

    static func _withInMemoryStoreForTesting<T>(
        _ body: () throws -> T
    ) rethrows -> T {
        try $taskLocalStore.withValue(InMemorySecretStore()) {
            try body()
        }
    }

    /// Async-body variant for tests that drive async tool surfaces (e.g.
    /// `SandboxSecretSetTool.execute`) against the in-memory store.
    static func _withInMemoryStoreForTesting<T>(
        _ body: () async throws -> T
    ) async rethrows -> T {
        try await $taskLocalStore.withValue(InMemorySecretStore()) {
            try await body()
        }
    }

    private static func testingSave(_ value: String, account: String) -> (enabled: Bool, saved: Bool) {
        guard let store = activeInMemoryStore else {
            return (enabled: false, saved: false)
        }
        store.set(account, value)
        return (enabled: true, saved: true)
    }

    private static func testingGet(account: String) -> (enabled: Bool, value: String?) {
        guard let store = activeInMemoryStore else {
            return (enabled: false, value: nil)
        }
        return (enabled: true, value: store.get(account))
    }

    private static func testingDelete(account: String) -> (enabled: Bool, deleted: Bool) {
        guard let store = activeInMemoryStore else {
            return (enabled: false, deleted: false)
        }
        store.set(account, nil)
        return (enabled: true, deleted: true)
    }

    private static func testingAllAccounts() -> [String]? {
        activeInMemoryStore?.accounts()
    }

    @discardableResult
    public static func saveSecret(_ value: String, id: String, agentId: UUID) -> Bool {
        let account = "\(agentId.uuidString).\(id)"
        guard let valueData = value.data(using: .utf8) else { return false }

        let testing = testingSave(value, account: account)
        if testing.enabled {
            return testing.saved
        }
        if KeychainQueryHelpers.disablesKeychainForProcess { return false }
        let didWrite = Keychain.write(service: service, account: account, data: valueData)
        if didWrite { invalidateAccountsCache() }
        return didWrite
    }

    public static func getSecret(id: String, agentId: UUID) -> String? {
        let account = "\(agentId.uuidString).\(id)"

        let testing = testingGet(account: account)
        if testing.enabled {
            return testing.value
        }
        if KeychainQueryHelpers.disablesKeychainForProcess { return nil }
        return Keychain.read(service: service, account: account)
            .flatMap { String(data: $0, encoding: .utf8) }
    }

    @discardableResult
    public static func deleteSecret(id: String, agentId: UUID) -> Bool {
        let account = "\(agentId.uuidString).\(id)"

        let testing = testingDelete(account: account)
        if testing.enabled {
            return testing.deleted
        }
        if KeychainQueryHelpers.disablesKeychainForProcess { return true }
        let didDelete = Keychain.delete(service: service, account: account)
        if didDelete { invalidateAccountsCache() }
        return didDelete
    }

    /// Enumerates accounts then fetches each value individually.
    public static func getAllSecrets(agentId: UUID) -> [String: String] {
        let prefix = "\(agentId.uuidString)."

        var secrets: [String: String] = [:]
        for account in allAccounts() where account.hasPrefix(prefix) {
            let key = String(account.dropFirst(prefix.count))
            if let value = getSecret(id: key, agentId: agentId) {
                secrets[key] = value
            }
        }
        return secrets
    }

    /// Enumerates secret identifiers without decrypting their values.
    ///
    /// Prompt construction only needs to tell the model which secret names are
    /// available. Fetching the values here is both unnecessary and can hit the
    /// slow Keychain data-decryption path during ordinary chat composition.
    public static func secretIDs(agentId: UUID) -> [String] {
        let prefix = "\(agentId.uuidString)."
        return allAccounts()
            .filter { $0.hasPrefix(prefix) }
            .map { String($0.dropFirst(prefix.count)) }
            .sorted()
    }

    public static func deleteAllSecrets(agentId: UUID) {
        let prefix = "\(agentId.uuidString)."

        // In-memory store: purge matching entries directly. Without this,
        // an eval harness running many cases in one process would leak
        // one case's secrets into the next (per-case cleanup calls here).
        if let store = activeInMemoryStore {
            store.removeAll(prefix: prefix)
            return
        }

        if KeychainQueryHelpers.disablesKeychainForProcess { return }
        for account in allAccounts() where account.hasPrefix(prefix) {
            Keychain.delete(service: service, account: account)
        }
        invalidateAccountsCache()
    }

    // MARK: - Environment Safety

    /// Env var names that must never be overridden by user-defined secrets.
    private static let reservedEnvVarNames: Set<String> = [
        "PATH", "HOME", "SHELL", "USER", "LOGNAME",
        "LD_PRELOAD", "LD_LIBRARY_PATH", "DYLD_INSERT_LIBRARIES",
        "VIRTUAL_ENV", "OSAURUS_PLUGIN",
    ]

    /// Returns agent secrets with reserved env var names stripped out.
    static func getFilteredSecrets(agentId: UUID) -> [String: String] {
        getAllSecrets(agentId: agentId).filter { !reservedEnvVarNames.contains($0.key) }
    }

    /// Returns merged agent + plugin secrets with reserved names stripped out.
    /// Plugin secrets override agent secrets of the same name.
    static func mergedSecretsEnvironment(agentId: UUID, pluginId: String) -> [String: String] {
        var env = getFilteredSecrets(agentId: agentId)
        let pluginSecrets =
            ToolSecretsKeychain
            .getAllSecrets(for: pluginId, agentId: agentId)
            .filter { !reservedEnvVarNames.contains($0.key) }
        env.merge(pluginSecrets) { _, new in new }
        return env
    }

    /// Resolve the account-name memo off the caller's thread so the first
    /// synchronous `secretIDs` read on a latency-sensitive path (chat-preview
    /// composition runs on the main actor) finds a warm cache instead of a
    /// blocking `SecItemCopyMatching` + `LAContext` round-trip.
    public static func prewarmAccounts() {
        Task.detached(priority: .utility) {
            _ = allAccounts()
        }
    }

    // MARK: - Private

    private static let accountsCacheLock = NSLock()
    nonisolated(unsafe) private static var cachedAccounts: [String]?

    /// Drop the account-name memo after a mutation so the next read re-queries.
    private static func invalidateAccountsCache() {
        accountsCacheLock.lock()
        cachedAccounts = nil
        accountsCacheLock.unlock()
    }

    private static func allAccounts() -> [String] {
        if let accounts = testingAllAccounts() {
            return accounts
        }
        if KeychainQueryHelpers.disablesKeychainForProcess { return [] }

        accountsCacheLock.lock()
        let cached = cachedAccounts
        accountsCacheLock.unlock()
        if let cached {
            return cached
        }

        // `SecItemCopyMatching` takes a process-wide Keychain lock and has hung
        // the UI when reached from `secretIDs` during chat-preview composition
        // on the main thread. Account names change only through this type's own
        // writes, so memoize the enumeration and invalidate it on every
        // mutation.
        let accounts = Keychain.allAccounts(service: service)
        accountsCacheLock.lock()
        cachedAccounts = accounts
        accountsCacheLock.unlock()
        return accounts
    }
}
