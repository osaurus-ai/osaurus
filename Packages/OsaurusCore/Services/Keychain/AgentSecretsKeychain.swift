//
//  AgentSecretsKeychain.swift
//  osaurus
//
//  Agent secrets saved before the Keys store (`sandbox_secret_set`, the
//  secret prompt, the agent's Sandbox page). Read-only: the Keys store
//  imports them as each agent's own keys and reads them as a fallback until
//  then. Nothing here writes or deletes a Keychain item.
//

import Foundation
import Security

/// Legacy agent-scoped secrets. Account format: `"{agentId}.{key}"`.
public enum AgentSecretsKeychain {
    private static let service = "ai.osaurus.agent-secrets"

    // MARK: - In-Memory Store (tests)

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

    /// Legacy items for migration and fallback tests, bound per task tree
    /// so parallel suites each get their own.
    @TaskLocal private static var activeInMemoryStore: InMemorySecretStore?

    static func _withInMemoryStoreForTesting<T>(
        _ body: () throws -> T
    ) rethrows -> T {
        try $activeInMemoryStore.withValue(InMemorySecretStore()) {
            try body()
        }
    }

    /// Async-body variant for tests that drive async tool surfaces (e.g.
    /// `SandboxSecretSetTool.execute`) against the in-memory store.
    static func _withInMemoryStoreForTesting<T>(
        _ body: @Sendable () async throws -> T
    ) async rethrows -> T {
        try await $activeInMemoryStore.withValue(InMemorySecretStore()) {
            try await body()
        }
    }

    private static func testingGet(account: String) -> (enabled: Bool, value: String?) {
        guard let store = activeInMemoryStore else {
            return (enabled: false, value: nil)
        }
        return (enabled: true, value: store.get(account))
    }

    private static func testingAllAccounts() -> [String]? {
        activeInMemoryStore?.accounts()
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

    /// Enumerates accounts then fetches each value individually.
    private static func allSecrets(agentId: UUID) -> [String: String] {
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

    /// Secret *names* for `agentId`, for listing in the system prompt so the
    /// model knows which env vars exist. Non-blocking: this is reached
    /// synchronously from chat-preview composition on the main actor, and a
    /// cold-cache enumeration takes the process-wide Keychain lock (the
    /// SecItemCopyMatching that hung the UI). On a cold cache we kick the
    /// background seed and return `[]`; the next compose (seed lands in ms,
    /// and composes re-run on every budget/input change) lists the real
    /// names. The legacy import and env fallback, which must be exact, go
    /// through the blocking `allAccounts()`.
    public static func secretIDs(agentId: UUID) -> [String] {
        let prefix = "\(agentId.uuidString)."
        return cachedAccountsOrSeed()
            .filter { $0.hasPrefix(prefix) }
            .map { String($0.dropFirst(prefix.count)) }
            .sorted()
    }

    // MARK: - Legacy (read-only) access for CredentialStore

    /// `<service>/<account>` id the credential migration tracks for an item.
    static func legacyId(agentId: UUID, key: String) -> String {
        "\(service)/\(agentId.uuidString).\(key)"
    }

    /// Legacy values for `agentId`, reserved names stripped. Read-only:
    /// the unified store copies these and never writes back.
    static func legacyFilteredSecrets(agentId: UUID) -> [String: String] {
        allSecrets(agentId: agentId).filter { !CredentialResolver.isReservedEnvVar($0.key) }
    }

    /// Every legacy (agent, key) pair, for the one-way import.
    /// `isDefinitive` is false when the Keychain was locked or failed, so an
    /// empty list means "couldn't look", not "nothing there".
    static func legacyEntries() -> (entries: [(agentId: UUID, key: String)], isDefinitive: Bool) {
        let listing = allAccountsListing()
        let entries = listing.accounts.compactMap { account -> (agentId: UUID, key: String)? in
            guard account.count > 37,
                let agentId = UUID(uuidString: String(account.prefix(36))),
                account[account.index(account.startIndex, offsetBy: 36)] == "."
            else { return nil }
            return (agentId, String(account.dropFirst(37)))
        }
        return (entries, listing.isDefinitive)
    }

    /// Resolve the account-name memo off the caller's thread so the first
    /// synchronous `secretIDs` read on a latency-sensitive path (chat-preview
    /// composition runs on the main actor) finds a warm cache instead of a
    /// blocking `SecItemCopyMatching` + `LAContext` round-trip.
    public static func prewarmAccounts() {
        // Single-flight: a cold read can be reached from every compose while
        // the seed is still in flight (or from every compose forever while
        // the keychain is locked and the enumeration stays non-definitive),
        // and each spawn would take the process-wide Keychain lock again.
        accountsCacheLock.lock()
        let shouldSeed = cachedAccounts == nil && !seedInFlight
        if shouldSeed { seedInFlight = true }
        accountsCacheLock.unlock()
        guard shouldSeed else { return }
        Task.detached(priority: .utility) {
            _ = allAccounts()
            clearSeedInFlight()
        }
    }

    /// Synchronous so the detached seed can take the lock; bare `lock()` /
    /// `unlock()` are unavailable inside async contexts.
    private static func clearSeedInFlight() {
        accountsCacheLock.lock()
        seedInFlight = false
        accountsCacheLock.unlock()
    }

    // MARK: - Private

    private static let accountsCacheLock = NSLock()
    nonisolated(unsafe) private static var cachedAccounts: [String]?

    /// Return the memoized account names without ever blocking on the
    /// Keychain. Warm cache → the names. Cold cache → kick the background
    /// seed and return `[]` (the caller re-reads on a later pass). The
    /// in-memory test store and disabled-keychain postures resolve inline
    /// since neither can block. Backs the display-only `secretIDs` reader.
    private static func cachedAccountsOrSeed() -> [String] {
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
        prewarmAccounts()
        return []
    }

    nonisolated(unsafe) private static var seedInFlight = false

    private static func allAccounts() -> [String] {
        allAccountsListing().accounts
    }

    private static func allAccountsListing() -> (accounts: [String], isDefinitive: Bool) {
        if let accounts = testingAllAccounts() {
            return (accounts, true)
        }
        if KeychainQueryHelpers.disablesKeychainForProcess { return ([], true) }

        accountsCacheLock.lock()
        let cached = cachedAccounts
        accountsCacheLock.unlock()
        if let cached {
            return (cached, true)
        }

        // `SecItemCopyMatching` takes a process-wide Keychain lock and has hung
        // the UI when reached from `secretIDs` during chat-preview composition
        // on the main thread. Nothing writes this service anymore, so memoize
        // the enumeration. Only a definitive enumeration is cached: a locked or
        // transiently failing keychain must not latch an empty account list.
        let outcome = Keychain.fetchAllItems(service: service, returnData: false)
        let accounts = outcome.items.compactMap { $0[kSecAttrAccount as String] as? String }
        if outcome.isDefinitive {
            accountsCacheLock.lock()
            cachedAccounts = accounts
            accountsCacheLock.unlock()
        }
        return (accounts, outcome.isDefinitive)
    }

    // MARK: - Test seams

    /// Seeds a legacy item in the in-memory store bound by
    /// `_withInMemoryStoreForTesting`. False when no in-memory store is active.
    @discardableResult
    static func _testSeedSecret(_ value: String, id: String, agentId: UUID) -> Bool {
        guard let store = activeInMemoryStore else { return false }
        store.set("\(agentId.uuidString).\(id)", value)
        return true
    }

    static func _testRemoveAll(agentId: UUID) {
        activeInMemoryStore?.removeAll(prefix: "\(agentId.uuidString).")
    }
}
