//
//  CredentialStore.swift
//  osaurus
//
//  The single store for agent-usable secrets and settings.
//
//  - Secret values: Keychain service `ai.osaurus.credentials`, accounts
//    `global/<KEY>` and `agent/<uuid-lowercased>/<KEY>`, stored
//    `WhenUnlockedThisDeviceOnly` like the legacy items: never synced, and
//    unreadable while the Mac is locked, so automations that run then can't
//    use hidden values.
//  - Metadata (and variable values): `credentials/index.json`. Listing and
//    presence checks read the index only, never the Keychain.
//  - Bindings (consumer slot -> key): `credentials/bindings.json`. Consumer
//    config files (`mcp.json`, workflow installs, channel configs) are never
//    rewritten to hold bindings.
//

import Foundation
import Security

public final class CredentialStore: @unchecked Sendable {
    static let service = OsaurusKeychainServices.credentials
    /// Longest value accepted, enough for PEM keys and certificate chains.
    public static let maxValueBytes = 64 * 1024

    // MARK: - Instances

    /// Process-wide store backed by `OsaurusPaths.credentials()`.
    public static let shared = CredentialStore()

    /// Test/harness override bound for a task tree.
    @TaskLocal static var taskLocalStore: CredentialStore?

    /// The store every consumer reads and writes.
    public static var current: CredentialStore { taskLocalStore ?? shared }

    /// Runs `body` against a fresh isolated store (in-memory secrets, a
    /// temporary directory for the index). Parallel suites each get their own.
    static func _withIsolatedStoreForTesting<T>(_ body: () throws -> T) rethrows -> T {
        try $taskLocalStore.withValue(CredentialStore.makeIsolated()) { try body() }
    }

    static func _withIsolatedStoreForTesting<T>(_ body: @Sendable () async throws -> T) async rethrows -> T {
        try await $taskLocalStore.withValue(CredentialStore.makeIsolated()) { try await body() }
    }

    static func makeIsolated() -> CredentialStore {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("osaurus-credentials-\(UUID().uuidString)", isDirectory: true)
        return CredentialStore(directory: dir, inMemorySecrets: true)
    }

    // MARK: - State

    private let directoryOverride: URL?
    private let forcesInMemorySecrets: Bool
    private let lock = NSLock()

    private var loadedDirectory: URL?
    private var index = CredentialIndexFile()
    private var bindings = CredentialBindingsFile()
    /// Secret values read or written this session, keyed by account.
    private var valueCache: [String: String] = [:]
    /// In-memory secret backend (tests, Keychain-free harnesses).
    private var memorySecrets: [String: String] = [:]
    /// Set while an unreadable file has no backup yet or the index is
    /// waiting on the Keychain to rebuild; writes stay in memory.
    private var indexPersistBlocked = false
    private var bindingsPersistBlocked = false
    private var loadNotices: [CredentialLoadIssue] = []
    private var _failsSecretWritesForTesting = false

    /// Tests: every secret write reports a Keychain failure.
    var failsSecretWritesForTesting: Bool {
        get { lock.withLock { _failsSecretWritesForTesting } }
        set { lock.withLock { _failsSecretWritesForTesting = newValue } }
    }

    init(directory: URL? = nil, inMemorySecrets: Bool = false) {
        self.directoryOverride = directory
        self.forcesInMemorySecrets = inMemorySecrets
    }

    private var directory: URL { directoryOverride ?? OsaurusPaths.credentials() }

    /// Unit tests, the eval CLI, and Keychain-free live proofs keep secrets in
    /// memory so the pipeline is exercised without touching the login Keychain.
    var usesMemorySecrets: Bool {
        if forcesInMemorySecrets { return true }
        let env = ProcessInfo.processInfo.environment
        return KeychainQueryHelpers.usesInMemoryKeychainStoreForTests
            || env["OSAURUS_CREDENTIALS_IN_MEMORY"] == "1"
    }

    // MARK: - Loading

    private enum FileLoad<T> {
        case missing
        case loaded(T)
        /// Present but unreadable or undecodable. Never overwritten until a
        /// backup copy exists.
        case unreadable
    }

    /// Caller holds `lock`. Reloads when the root moved (tests swap
    /// `OsaurusPaths.overrideRoot`).
    private func ensureLoadedLocked() {
        let dir = directory
        guard loadedDirectory != dir else { return }
        loadedDirectory = dir
        valueCache.removeAll()
        indexPersistBlocked = false
        bindingsPersistBlocked = false
        loadNotices = []

        switch Self.load(CredentialIndexFile.self, at: indexURL) {
        case .missing: index = .init()
        case .loaded(let file): index = file
        case .unreadable: recoverIndexLocked()
        }

        switch Self.load(CredentialBindingsFile.self, at: bindingsURL) {
        case .missing: bindings = .init()
        case .loaded(let file): bindings = file
        case .unreadable:
            bindings = .init()
            if let backup = Self.backUp(bindingsURL) {
                loadNotices.append(.bindingsReset(backup: backup))
            } else {
                bindingsPersistBlocked = true
            }
        }
    }

    private var indexURL: URL { directory.appendingPathComponent("index.json") }
    private var bindingsURL: URL { directory.appendingPathComponent("bindings.json") }

    private static func load<T: Decodable>(_ type: T.Type, at url: URL) -> FileLoad<T> {
        guard FileManager.default.fileExists(atPath: url.path) else { return .missing }
        guard let data = try? Data(contentsOf: url) else { return .unreadable }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let value = try? decoder.decode(type, from: data) else { return .unreadable }
        return .loaded(value)
    }

    /// Copies an unreadable file aside (`<name>.corrupt-<timestamp>.json`).
    private static func backUp(_ url: URL) -> URL? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let name = url.deletingPathExtension().lastPathComponent
        let backup = url.deletingLastPathComponent()
            .appendingPathComponent("\(name).corrupt-\(formatter.string(from: Date())).json")
        do {
            if FileManager.default.fileExists(atPath: backup.path) { return backup }
            try FileManager.default.copyItem(at: url, to: backup)
            return backup
        } catch {
            NSLog("CredentialStore: could not back up \(url.lastPathComponent): \(error.localizedDescription)")
            return nil
        }
    }

    /// Caller holds `lock`. The index is unreadable: keep a copy, then rebuild
    /// the secret records from the Keychain so nothing the user saved is
    /// re-imported over or forgotten. Variable values lived only in the index
    /// and stay in the backup.
    private func recoverIndexLocked() {
        index = .init()
        guard let backup = Self.backUp(indexURL) else {
            indexPersistBlocked = true
            return
        }
        guard let rebuilt = rebuildRecordsFromSecretsLocked() else {
            // Keychain locked or unavailable: retry later, write nothing now.
            indexPersistBlocked = true
            loadNotices.append(.indexRecoveryPending(backup: backup))
            return
        }
        index.records = rebuilt
        loadNotices.append(.indexRebuilt(backup: backup, recovered: rebuilt.count))
        persistIndexLocked()
    }

    /// Records for every secret stored under this store's Keychain service,
    /// or nil when the listing isn't authoritative.
    private func rebuildRecordsFromSecretsLocked() -> [CredentialRecord]? {
        let accounts: [String]
        if usesMemorySecrets {
            accounts = Array(memorySecrets.keys)
        } else {
            let listing = Keychain.fetchAllItems(service: Self.service, returnData: false)
            guard listing.isDefinitive else { return nil }
            accounts = listing.items.compactMap { $0[kSecAttrAccount as String] as? String }
        }
        return accounts.compactMap(CredentialScope.parse(account:))
            .map { scope, key in
                CredentialRecord(key: key, scope: scope, kind: .secret, exposeToSandbox: false, origin: .user)
            }
            .sorted { ($0.key, $0.id) < ($1.key, $1.id) }
    }

    /// Retries a recovery that was waiting for the Keychain. Called before
    /// each import pass (which also runs on unlock).
    func retryRecoveryIfNeeded() {
        lock.lock()
        defer { lock.unlock() }
        ensureLoadedLocked()
        guard indexPersistBlocked, let rebuilt = rebuildRecordsFromSecretsLocked() else { return }
        let backup = loadNotices.compactMap(\.backup).first
        var merged = rebuilt.filter { rebuiltRecord in !index.records.contains { $0.id == rebuiltRecord.id } }
        merged.append(contentsOf: index.records)
        index.records = merged.sorted { ($0.key, $0.id) < ($1.key, $1.id) }
        indexPersistBlocked = false
        loadNotices.removeAll { if case .indexRecoveryPending = $0 { return true } else { return false } }
        if let backup { loadNotices.append(.indexRebuilt(backup: backup, recovered: rebuilt.count)) }
        persistIndexLocked()
    }

    /// Problems found reading the files on disk, for the Keys page.
    public func loadIssues() -> [CredentialLoadIssue] {
        withLock { loadNotices }
    }

    @discardableResult
    private func persistIndexLocked() -> Bool {
        guard !indexPersistBlocked else { return false }
        return write(index, to: indexURL)
    }

    @discardableResult
    private func persistBindingsLocked() -> Bool {
        guard !bindingsPersistBlocked else { return false }
        return write(bindings, to: bindingsURL)
    }

    private func write<T: Encodable>(_ value: T, to url: URL) -> Bool {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(value) else { return false }
        let dir = url.deletingLastPathComponent()
        let fm = FileManager.default
        do {
            if !fm.fileExists(atPath: dir.path) {
                try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            }
            try data.write(to: url, options: .atomic)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            return true
        } catch {
            NSLog("CredentialStore: failed to write \(url.lastPathComponent): \(error.localizedDescription)")
            return false
        }
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        ensureLoadedLocked()
        return body()
    }

    /// Posted with the store as the object so observers can ignore test
    /// stores.
    func notifyChanged(keys: [String]) {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .credentialsDidChange, object: self, userInfo: ["keys": keys])
        }
    }

    /// Runs `body` off the main thread. Keychain calls can block for seconds
    /// (a locked keychain or an access prompt), so views save and delete here.
    public func perform<T: Sendable>(_ body: @escaping @Sendable (CredentialStore) -> T) async -> T {
        await Task.detached(priority: .userInitiated) { [self] in
            Self.$taskLocalStore.withValue(self) { body(self) }
        }.value
    }

    // MARK: - Reading metadata (index only)

    public func allRecords() -> [CredentialRecord] {
        withLock { index.records }
    }

    public func records(in scope: CredentialScope) -> [CredentialRecord] {
        withLock { index.records.filter { $0.scope == scope } }
    }

    public func record(_ key: String, scope: CredentialScope) -> CredentialRecord? {
        withLock { index.records.first { $0.key == key && $0.scope == scope } }
    }

    /// Presence from the index alone; never touches the Keychain.
    public func hasValue(_ key: String, scope: CredentialScope) -> Bool {
        record(key, scope: scope) != nil
    }

    // MARK: - Reading values

    /// The stored value for exactly this scope (no fallback).
    public func value(_ key: String, scope: CredentialScope) -> String? {
        lock.lock()
        ensureLoadedLocked()
        guard let record = index.records.first(where: { $0.key == key && $0.scope == scope }) else {
            lock.unlock()
            return nil
        }
        if record.kind == .variable {
            lock.unlock()
            return record.variableValue
        }
        let account = scope.account(for: key)
        if let cached = valueCache[account] {
            lock.unlock()
            return cached
        }
        if usesMemorySecrets {
            let value = memorySecrets[account]
            lock.unlock()
            return value
        }
        lock.unlock()

        let outcome = Keychain.readItem(service: Self.service, account: account)
        guard case .found(let data) = outcome, let value = String(data: data, encoding: .utf8) else {
            return nil
        }
        withLock { valueCache[account] = value }
        return value
    }

    /// Typed availability for diagnostics; `.absent` comes from the index.
    public func availability(_ key: String, scope: CredentialScope) -> SecretAvailability {
        guard let record = record(key, scope: scope) else { return .absent }
        if record.kind == .variable { return record.variableValue == nil ? .absent : .present }
        if usesMemorySecrets { return value(key, scope: scope) == nil ? .absent : .present }
        switch Keychain.readItem(service: Self.service, account: scope.account(for: key)) {
        case .found: return .present
        case .notFound, .disabled: return .absent
        case .unavailable, .accessDenied, .failure: return .unavailable
        }
    }

    /// When a secret for `key` is stored under this scope but the index has
    /// no record of it (the index was lost), adds the record back and
    /// returns true. Imports call this so they never write over it.
    @discardableResult
    func adoptStoredSecret(_ key: String, scope: CredentialScope) -> Bool {
        guard record(key, scope: scope) == nil else { return false }
        let account = scope.account(for: key)
        let value: String?
        if usesMemorySecrets {
            value = withLock { memorySecrets[account] }
        } else if case .found(let data) = Keychain.readItem(service: Self.service, account: account) {
            value = String(data: data, encoding: .utf8)
        } else {
            value = nil
        }
        guard let value else { return false }
        withLock {
            guard !index.records.contains(where: { $0.key == key && $0.scope == scope }) else { return }
            index.records.append(
                CredentialRecord(key: key, scope: scope, kind: .secret, exposeToSandbox: false, origin: .user))
            index.records.sort { ($0.key, $0.id) < ($1.key, $1.id) }
            valueCache[account] = value
            persistIndexLocked()
        }
        notifyChanged(keys: [key])
        return true
    }

    // MARK: - Writing

    /// Create or update a credential. Metadata arguments left `nil` keep the
    /// existing record's values (or the origin's defaults for a new record).
    @discardableResult
    public func save(
        _ key: String,
        scope: CredentialScope,
        value: String,
        kind: CredentialKind? = nil,
        description: String? = nil,
        exposeToSandbox: Bool? = nil,
        origin: CredentialOrigin
    ) -> CredentialWriteOutcome {
        guard CredentialKeys.isValid(key) else { return .invalidKey }
        guard !value.isEmpty else { return .emptyValue }
        guard value.utf8.count <= Self.maxValueBytes else { return .valueTooLong }

        let existing = record(key, scope: scope)
        let resolvedKind = kind ?? existing?.kind ?? .secret
        let account = scope.account(for: key)

        if resolvedKind == .secret {
            if failsSecretWritesForTesting {
                return .keychainFailure("Simulated Keychain failure")
            } else if usesMemorySecrets {
                withLock { memorySecrets[account] = value }
            } else {
                guard let data = value.data(using: .utf8) else { return .emptyValue }
                let outcome = Keychain.writeItem(service: Self.service, account: account, data: data)
                guard outcome.isSuccess else { return .keychainFailure(Self.describe(outcome)) }
            }
        } else if existing?.kind == .secret {
            removeSecretValue(account: account)
        }

        let now = Date()
        let persisted: Bool = withLock {
            var record =
                existing
                ?? CredentialRecord(
                    key: key,
                    scope: scope,
                    kind: resolvedKind,
                    exposeToSandbox: exposeToSandbox ?? origin.exposesToSandboxByDefault,
                    origin: origin,
                    createdAt: now
                )
            record.kind = resolvedKind
            if let description { record.description = description }
            if let exposeToSandbox { record.exposeToSandbox = exposeToSandbox }
            record.variableValue = resolvedKind == .variable ? value : nil
            record.updatedAt = now
            index.records.removeAll { $0.key == key && $0.scope == scope }
            index.records.append(record)
            index.records.sort { ($0.key, $0.id) < ($1.key, $1.id) }
            if resolvedKind == .secret { valueCache[account] = value } else { valueCache[account] = nil }
            index.deletedAccounts.remove(account)
            return persistIndexLocked()
        }
        notifyChanged(keys: [key])
        return persisted ? .success : .indexWriteFailed
    }

    /// Change non-secret metadata without touching the value.
    public func updateMetadata(
        _ key: String,
        scope: CredentialScope,
        description: String? = nil,
        exposeToSandbox: Bool? = nil
    ) {
        let changed: Bool = withLock {
            guard let i = index.records.firstIndex(where: { $0.key == key && $0.scope == scope }) else {
                return false
            }
            if let description { index.records[i].description = description }
            if let exposeToSandbox { index.records[i].exposeToSandbox = exposeToSandbox }
            index.records[i].updatedAt = Date()
            persistIndexLocked()
            return true
        }
        if changed { notifyChanged(keys: [key]) }
    }

    /// Removes the value and leaves a tombstone so the legacy fallback and
    /// migration never bring it back. Nothing changes when the Keychain
    /// refuses the delete.
    @discardableResult
    public func delete(_ key: String, scope: CredentialScope) -> CredentialWriteOutcome {
        let account = scope.account(for: key)
        if record(key, scope: scope)?.kind != .variable {
            let removed = removeSecretValue(account: account)
            guard removed.isSuccess else { return removed }
        }
        let persisted: Bool = withLock {
            index.records.removeAll { $0.key == key && $0.scope == scope }
            valueCache[account] = nil
            index.deletedAccounts.insert(account)
            return persistIndexLocked()
        }
        notifyChanged(keys: [key])
        return persisted ? .success : .indexWriteFailed
    }

    /// Whether `key` was deleted in exactly this scope and not saved since.
    public func isDeleted(_ key: String, scope: CredentialScope) -> Bool {
        withLock { index.deletedAccounts.contains(scope.account(for: key)) }
    }

    /// Removes every credential saved for `agentId` (new store only). Keys
    /// the Keychain refused to delete stay listed.
    @discardableResult
    public func deleteAll(agentId: UUID) -> CredentialWriteOutcome {
        let scope = CredentialScope.agent(agentId)
        var outcome = CredentialWriteOutcome.success
        for key in records(in: scope).map(\.key) {
            let result = delete(key, scope: scope)
            if !result.isSuccess { outcome = result }
        }
        return outcome
    }

    /// Renames `oldKey` in every scope and repoints bindings at the new key.
    /// Fails without changes when `newKey` already exists in any scope that
    /// `oldKey` uses, or when a current value can't be read.
    @discardableResult
    public func rename(_ oldKey: String, to newKey: String) -> CredentialWriteOutcome {
        guard CredentialKeys.isValid(newKey) else { return .invalidKey }
        guard oldKey != newKey else { return .success }
        let moving = allRecords().filter { $0.key == oldKey }
        if moving.contains(where: { hasValue(newKey, scope: $0.scope) }) { return .nameInUse }

        var values: [(record: CredentialRecord, value: String)] = []
        for record in moving {
            let value = record.kind == .secret ? value(oldKey, scope: record.scope) : record.variableValue
            guard let value, !value.isEmpty else {
                return .keychainFailure("the current value of \(oldKey) couldn't be read")
            }
            values.append((record, value))
        }

        var saved: [CredentialScope] = []
        for (record, value) in values {
            let outcome = save(
                newKey, scope: record.scope, value: value, kind: record.kind,
                description: record.description, exposeToSandbox: record.exposeToSandbox,
                origin: record.origin)
            guard outcome.isSuccess else {
                for scope in saved { delete(newKey, scope: scope) }
                return outcome
            }
            saved.append(record.scope)
        }
        for record in moving { delete(oldKey, scope: record.scope) }
        let persisted: Bool = withLock {
            for (slot, key) in bindings.slots where key == oldKey { bindings.slots[slot] = newKey }
            return persistBindingsLocked()
        }
        notifyChanged(keys: [oldKey, newKey])
        return persisted ? .success : .indexWriteFailed
    }

    private func removeSecretValue(account: String) -> CredentialWriteOutcome {
        if failsSecretWritesForTesting { return .keychainFailure("Simulated Keychain failure") }
        if usesMemorySecrets {
            withLock { _ = memorySecrets.removeValue(forKey: account) }
            return .success
        }
        let outcome = Keychain.deleteItem(service: Self.service, account: account)
        return outcome.isSuccess ? .success : .keychainFailure(Self.describe(outcome))
    }

    private static func describe(_ outcome: KeychainMutationOutcome) -> String {
        switch outcome {
        case .success: return "ok"
        case .unavailable: return "the Keychain is locked or unavailable"
        case .accessDenied: return "access was denied"
        case .failure(let status): return "OSStatus \(status)"
        case .disabled: return "Keychain access is disabled for this process"
        }
    }

    // MARK: - Bindings

    /// The key explicitly bound to `slot`, if any. Callers fall back to the
    /// slot's default key when this is nil.
    public func boundKey(for slot: String) -> String? {
        withLock { bindings.slots[slot] }
    }

    public func allBindings() -> [String: String] {
        withLock { bindings.slots }
    }

    /// Bind `slot` to `key`; `nil` (or the slot's default) removes the entry.
    public func setBinding(slot: String, key: String?, defaultKey: String? = nil) {
        withLock {
            if let key, key != defaultKey {
                bindings.slots[slot] = key
            } else {
                bindings.slots.removeValue(forKey: slot)
            }
            persistBindingsLocked()
        }
        notifyChanged(keys: [key].compactMap { $0 })
    }

    // MARK: - Legacy import bookkeeping

    /// Whether a legacy item (`<service>/<account>`) was imported, or was
    /// otherwise handled (deleted through the new store), so the read-only
    /// legacy fallback must no longer serve it.
    public func hasImportedLegacy(_ legacyId: String) -> Bool {
        withLock { index.importedLegacy.contains(legacyId) }
    }

    func markLegacyImported(_ legacyIds: [String]) {
        guard !legacyIds.isEmpty else { return }
        withLock {
            index.importedLegacy.formUnion(legacyIds)
            persistIndexLocked()
        }
    }

    var migrationCompletedAt: Date? {
        withLock { index.migrationCompletedAt }
    }

    func markMigrationCompleted() {
        withLock {
            index.migrationCompletedAt = Date()
            persistIndexLocked()
        }
    }

    /// Re-reads the files on next access, keeping in-memory secrets (stands
    /// in for a relaunch against the same Keychain).
    func _reloadFromDiskForTesting() {
        lock.withLock {
            loadedDirectory = nil
            valueCache.removeAll()
        }
    }

    /// Drop cached state so the next access reloads from disk.
    func _resetForTesting() {
        lock.lock()
        loadedDirectory = nil
        valueCache.removeAll()
        memorySecrets.removeAll()
        lock.unlock()
    }
}

// MARK: - On-disk files

struct CredentialIndexFile: Codable, Equatable {
    var version = 1
    var records: [CredentialRecord] = []
    /// Legacy items (`<service>/<account>`) already copied in. Never
    /// re-imported, so a later edit in the new store is never overwritten.
    var importedLegacy: Set<String> = []
    var migrationCompletedAt: Date?
    /// Accounts (`global/KEY`, `agent/<uuid>/KEY`) deleted through the new
    /// store. The legacy fallback and migration never bring them back.
    var deletedAccounts: Set<String> = []

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        records = try c.decodeIfPresent([CredentialRecord].self, forKey: .records) ?? []
        importedLegacy = try c.decodeIfPresent(Set<String>.self, forKey: .importedLegacy) ?? []
        migrationCompletedAt = try c.decodeIfPresent(Date.self, forKey: .migrationCompletedAt)
        deletedAccounts = try c.decodeIfPresent(Set<String>.self, forKey: .deletedAccounts) ?? []
    }
}

struct CredentialBindingsFile: Codable, Equatable {
    var version = 1
    var slots: [String: String] = [:]
}
