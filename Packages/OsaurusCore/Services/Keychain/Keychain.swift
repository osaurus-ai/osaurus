//
//  Keychain.swift
//  osaurus
//
//  Shared generic-password (`kSecClassGenericPassword`) CRUD against the
//  macOS legacy (file-based login) keychain.
//

import Foundation
import Security
import os.log

// MARK: - Typed outcomes

/// Typed result of a Keychain read.
///
/// The distinction between `notFound` and `unavailable`/`accessDenied` is
/// load-bearing: a locked keychain or a denied ACL must never be reported to
/// the user as "credential missing", and must never be cached as absence.
enum KeychainReadOutcome: Equatable, Sendable {
    /// The item exists and its payload was returned.
    case found(Data)
    /// The item definitively does not exist (`errSecItemNotFound`).
    case notFound
    /// The item may exist but cannot be read right now (locked keychain,
    /// interaction required, securityd unavailable). Retry later.
    case unavailable(OSStatus)
    /// The keychain refused access to the item for this process (ACL denial,
    /// authorization failure). Manual repair is likely required.
    case accessDenied(OSStatus)
    /// Any other Security-framework failure.
    case failure(OSStatus)
    /// Keychain access is disabled for this process (test/live-proof mode).
    case disabled

    /// Payload when found, `nil` otherwise (legacy-compatible view).
    var data: Data? {
        if case .found(let data) = self { return data }
        return nil
    }

    /// True when the outcome is authoritative about existence (found,
    /// not-found, or disabled) and therefore safe to cache. Transient
    /// failures return false so callers do not latch a "missing" result.
    var isDefinitive: Bool {
        switch self {
        case .found, .notFound, .disabled: return true
        case .unavailable, .accessDenied, .failure: return false
        }
    }
}

/// Typed result of a Keychain mutation (write or delete).
enum KeychainMutationOutcome: Equatable, Sendable {
    case success
    /// The keychain cannot accept the mutation right now (locked,
    /// interaction required, securityd unavailable). Retry later.
    case unavailable(OSStatus)
    /// The keychain refused the mutation for this process.
    case accessDenied(OSStatus)
    case failure(OSStatus)
    /// Keychain access is disabled for this process (test/live-proof mode).
    case disabled

    var isSuccess: Bool { self == .success }
}

/// Enumeration result carrying both the items and whether the listing is
/// authoritative (so callers don't cache an empty list produced by a
/// transient failure).
struct KeychainEnumerationOutcome {
    let items: [[String: Any]]
    let status: OSStatus

    /// True when the listing reflects the real keychain contents
    /// (`errSecSuccess`/`errSecItemNotFound`) or the process-level disable
    /// gate; false for transient/denied/failed enumerations.
    let isDefinitive: Bool
}

// MARK: - Injectable backend

/// The raw SecItem surface, injectable so unit tests can exercise every
/// `OSStatus` path deterministically without a real keychain.
protocol KeychainBackend: Sendable {
    func copyMatching(_ query: [String: Any]) -> (status: OSStatus, result: AnyObject?)
    func update(query: [String: Any], attributes: [String: Any]) -> OSStatus
    func add(attributes: [String: Any]) -> OSStatus
    func delete(query: [String: Any]) -> OSStatus
}

/// Production backend: direct SecItem calls against the legacy login keychain.
private struct SecItemKeychainBackend: KeychainBackend {
    func copyMatching(_ query: [String: Any]) -> (status: OSStatus, result: AnyObject?) {
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        return (status, result)
    }

    func update(query: [String: Any], attributes: [String: Any]) -> OSStatus {
        SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
    }

    func add(attributes: [String: Any]) -> OSStatus {
        SecItemAdd(attributes as CFDictionary, nil)
    }

    func delete(query: [String: Any]) -> OSStatus {
        SecItemDelete(query as CFDictionary)
    }
}

// MARK: - Keychain

/// Generic-password CRUD used by every secret store in the app.
///
/// Reads run with `kSecUseAuthenticationUISkip` plus a non-interactive
/// `LAContext` so a query that the item's ACL would otherwise gate fails
/// silently (returns a typed non-found outcome) instead of raising the
/// "wants to use your confidential information" password prompt. Because
/// release builds keep a stable Developer ID Designated Requirement (same
/// cert + bundle id), the keychain treats update N+1 as the same app as
/// update N, so legitimately owned items read back without any prompt across
/// updates.
///
/// The `KeychainQueryHelpers.disablesKeychainForProcess` gate is enforced
/// centrally here for every operation, so no consumer can accidentally reach
/// the user's login keychain in test/live-proof mode. Wrapper stores keep
/// their own guards as well (they are pinned by the live-proof source
/// assertions), but the central gate covers direct callers too.
enum Keychain {
    private static let log = Logger(subsystem: "com.dinoki.osaurus", category: "Keychain")

    /// Serial queue for all mutations. `SecItemAdd`/`SecItemUpdate` are
    /// synchronous and can block for seconds under iCloud-keychain or
    /// first-unlock contention; running them here keeps that I/O off the main
    /// thread (a recurring app-hang source). Serial so concurrent writes to
    /// the same item don't race, and so `flushPendingWrites` has a single
    /// queue to drain at quit.
    private static let writeQueue: DispatchQueue = {
        let queue = DispatchQueue(label: "com.dinoki.osaurus.keychain.write", qos: .utility)
        queue.setSpecific(key: writeQueueKey, value: ())
        return queue
    }()

    /// Marks code already running on `writeQueue` so synchronous mutations
    /// invoked from inside a `performInBackground` batch don't deadlock on a
    /// nested `sync` to the same serial queue.
    private static let writeQueueKey = DispatchSpecificKey<Void>()

    /// Concurrent executor for blocking reads. Reads do not participate in
    /// mutation ordering, so a slow securityd read must not delay unrelated
    /// reads or the bounded mutation flush used during termination.
    private static let readQueue = DispatchQueue(
        label: "com.dinoki.osaurus.keychain.read",
        qos: .utility,
        attributes: .concurrent
    )

    private struct BackendAccess: @unchecked Sendable {
        let backend: any KeychainBackend
        let bypassesDisableGate: Bool
        let isDisabled: @Sendable () -> Bool
    }

    @TaskLocal private static var testBackendOverride: BackendAccess?
    private static let productionBackend = SecItemKeychainBackend()

    /// Scope a fake backend to one test task. Child tasks inherit the scope,
    /// while unrelated tests keep using the production/disabled path.
    static func _withBackendForTesting<T>(
        _ backend: any KeychainBackend,
        bypassesDisableGate: Bool = true,
        isDisabled: @escaping @Sendable () -> Bool = {
            KeychainQueryHelpers.disablesKeychainForProcess
        },
        operation: () throws -> T
    ) rethrows -> T {
        try $testBackendOverride.withValue(
            BackendAccess(
                backend: backend,
                bypassesDisableGate: bypassesDisableGate,
                isDisabled: isDisabled
            ),
            operation: operation
        )
    }

    static func _withBackendForTesting<T>(
        _ backend: any KeychainBackend,
        bypassesDisableGate: Bool = true,
        isDisabled: @escaping @Sendable () -> Bool = {
            KeychainQueryHelpers.disablesKeychainForProcess
        },
        operation: () async throws -> T
    ) async rethrows -> T {
        try await $testBackendOverride.withValue(
            BackendAccess(
                backend: backend,
                bypassesDisableGate: bypassesDisableGate,
                isDisabled: isDisabled
            ),
            operation: operation
        )
    }

    /// True only while this task is inside a scoped injected-backend context.
    /// This is deliberately TaskLocal: queue hops made through `perform`
    /// carry the fake backend, while detached/unscoped work cannot authorize
    /// itself to bypass process-level Keychain isolation.
    static var hasInjectedBackendForCurrentContext: Bool {
        testBackendOverride != nil
    }

    private static func currentBackend() -> BackendAccess {
        if let override = testBackendOverride { return override }
        return BackendAccess(
            backend: productionBackend,
            bypassesDisableGate: false,
            isDisabled: { KeychainQueryHelpers.disablesKeychainForProcess }
        )
    }

    /// Execute one raw backend call behind the final process-isolation check.
    /// This must wrap every individual SecItem operation because a queued
    /// mutation may wait after its entry guard has already passed.
    private static func performBackendOperation<Result>(
        access: BackendAccess,
        operation: () -> Result
    ) -> Result? {
        if access.bypassesDisableGate { return operation() }
        return KeychainQueryHelpers.performIfAccessRemainsAllowed(
            isDisabled: access.isDisabled,
            operation: operation
        )
    }

    private static func baseQuery(service: String, account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    // MARK: - Status classification

    /// Statuses that mean "the keychain can't answer right now" — retryable.
    private static func isUnavailableStatus(_ status: OSStatus) -> Bool {
        switch status {
        case errSecInteractionNotAllowed,  // locked keychain / ACL wants UI we suppressed
            errSecNotAvailable,  // no keychain available (early boot, securityd down)
            errSecInteractionRequired:
            return true
        default:
            return false
        }
    }

    /// Statuses that mean "this process was refused access" — likely
    /// permanent for the current signing identity.
    private static func isAccessDeniedStatus(_ status: OSStatus) -> Bool {
        status == errSecAuthFailed || status == errSecUserCanceled
    }

    private static func readOutcome(for status: OSStatus, result: AnyObject?) -> KeychainReadOutcome {
        switch status {
        case errSecSuccess:
            guard let data = result as? Data else { return .failure(errSecDecode) }
            return .found(data)
        case errSecItemNotFound:
            return .notFound
        case _ where isUnavailableStatus(status):
            return .unavailable(status)
        case _ where isAccessDeniedStatus(status):
            return .accessDenied(status)
        default:
            return .failure(status)
        }
    }

    private static func mutationOutcome(for status: OSStatus) -> KeychainMutationOutcome {
        switch status {
        case errSecSuccess:
            return .success
        case _ where isUnavailableStatus(status):
            return .unavailable(status)
        case _ where isAccessDeniedStatus(status):
            return .accessDenied(status)
        default:
            return .failure(status)
        }
    }

    /// Privacy-safe failure log: service + operation + status only. Never the
    /// account name (it can embed provider/plugin identifiers) or the value.
    private static func logFailure(_ operation: String, service: String, status: OSStatus) {
        log.error(
            "Keychain \(operation, privacy: .public) failed for service \(service, privacy: .public): OSStatus \(status, privacy: .public)"
        )
    }

    // MARK: - Mutation serialization

    /// Run `work` on the serial write queue, reentrancy-safe: if the caller
    /// is already on the queue (e.g. inside a `performInBackground` batch)
    /// the work runs inline instead of deadlocking on a nested `sync`.
    private static func onWriteQueueSync<T>(_ work: () -> T) -> T {
        if DispatchQueue.getSpecific(key: writeQueueKey) != nil {
            return work()
        }
        // Ledger entry (main thread only): a synchronous mutation from the
        // main thread waits behind every queued background write PLUS its
        // own SecItem call — the classic securityd-contention stall shape.
        // With the entry, a watchdog breach names "keychain.mutation-sync"
        // instead of logging a generic hang.
        return MainThreadOperationLedger.shared.withMainThreadOperation(
            subsystem: "keychain", operation: "mutation-sync"
        ) {
            writeQueue.sync(execute: work)
        }
    }

    /// Block until every mutation enqueued so far has completed, bounded by
    /// `timeout`. Called from `applicationWillTerminate` so a credential
    /// saved right before quit isn't dropped when `_exit` skips the queue.
    @discardableResult
    static func flushPendingWrites(timeout: TimeInterval = 3.0) -> Bool {
        let done = DispatchSemaphore(value: 0)
        writeQueue.async { done.signal() }
        if done.wait(timeout: .now() + timeout) == .timedOut {
            log.error("Keychain flushPendingWrites timed out after \(timeout, privacy: .public)s")
            return false
        }
        return true
    }

    // MARK: - Typed CRUD

    /// Upsert `data` for (`service`, `account`) with a typed outcome.
    ///
    /// Adds only after `errSecItemNotFound`: any other update failure is the
    /// real error and is surfaced directly instead of being hidden behind a
    /// guaranteed-duplicate `SecItemAdd` result.
    static func writeItem(
        service: String,
        account: String,
        data: Data,
        accessible: CFString = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
    ) -> KeychainMutationOutcome {
        let access = currentBackend()
        if !access.bypassesDisableGate, access.isDisabled() { return .disabled }
        return onWriteQueueSync {
            let base = baseQuery(service: service, account: account)
            // Accessibility is a creation-time attribute; the legacy keychain
            // ignores it on update and some paths reject it, so only the add
            // carries it.
            guard let updateStatus = performBackendOperation(access: access, operation: {
                access.backend.update(
                    query: base,
                    attributes: [kSecValueData as String: data]
                )
            }) else { return .disabled }
            if updateStatus == errSecSuccess { return .success }
            if updateStatus == errSecItemNotFound {
                var add = base
                add[kSecValueData as String] = data
                add[kSecAttrAccessible as String] = accessible
                guard let addStatus = performBackendOperation(access: access, operation: {
                    access.backend.add(attributes: add)
                }) else { return .disabled }
                if addStatus == errSecSuccess { return .success }
                logFailure("add", service: service, status: addStatus)
                return mutationOutcome(for: addStatus)
            }
            if isAccessDeniedStatus(updateStatus) {
                // The item exists but its ACL refuses this process (typically
                // written by a differently signed build). It can be neither
                // read nor updated by us, so there is nothing to preserve:
                // delete it and re-add once to reclaim the account.
                logFailure("update", service: service, status: updateStatus)
                guard let deleteStatus = performBackendOperation(access: access, operation: {
                    access.backend.delete(query: base)
                }) else { return .disabled }
                if deleteStatus == errSecSuccess || deleteStatus == errSecItemNotFound {
                    var add = base
                    add[kSecValueData as String] = data
                    add[kSecAttrAccessible as String] = accessible
                    guard let addStatus = performBackendOperation(access: access, operation: {
                        access.backend.add(attributes: add)
                    }) else { return .disabled }
                    if addStatus == errSecSuccess { return .success }
                    logFailure("add-after-denied", service: service, status: addStatus)
                    return mutationOutcome(for: addStatus)
                }
                logFailure("delete-after-denied", service: service, status: deleteStatus)
                return mutationOutcome(for: updateStatus)
            }
            logFailure("update", service: service, status: updateStatus)
            return mutationOutcome(for: updateStatus)
        }
    }

    /// Read (`service`, `account`) with a typed outcome distinguishing
    /// absence from transient unavailability and access denial.
    static func readItem(service: String, account: String) -> KeychainReadOutcome {
        let access = currentBackend()
        if !access.bypassesDisableGate, access.isDisabled() { return .disabled }
        var query = baseQuery(service: service, account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query.merge(
            [
                kSecUseAuthenticationUI as String: kSecUseAuthenticationUISkip,
                kSecUseAuthenticationContext as String: KeychainQueryHelpers.nonInteractiveContext(),
            ]
        ) { _, new in new }

        // Ledger entry (main thread only): `SecItemCopyMatching` is a
        // securityd XPC round-trip that has stalled the main thread for
        // seconds under contention (Sentry APPLE-MACOS-1B5). Naming it here
        // makes any watchdog breach attribute to "keychain.read".
        let response = MainThreadOperationLedger.shared.withMainThreadOperation(
            subsystem: "keychain", operation: "read"
        ) {
            performBackendOperation(access: access) {
                access.backend.copyMatching(query)
            }
        }
        guard let (status, result) = response else { return .disabled }
        let outcome = readOutcome(for: status, result: result)
        if case .found = outcome { return outcome }
        if case .notFound = outcome { return outcome }
        logFailure("read", service: service, status: status)
        return outcome
    }

    /// Delete (`service`, `account`) with a typed outcome. A missing item
    /// counts as success (the desired end state holds).
    static func deleteItem(service: String, account: String) -> KeychainMutationOutcome {
        let access = currentBackend()
        if !access.bypassesDisableGate, access.isDisabled() { return .disabled }
        return onWriteQueueSync {
            guard let status = performBackendOperation(access: access, operation: {
                access.backend.delete(query: baseQuery(service: service, account: account))
            }) else { return .disabled }
            if status == errSecSuccess || status == errSecItemNotFound { return .success }
            logFailure("delete", service: service, status: status)
            return mutationOutcome(for: status)
        }
    }

    /// Delete every generic-password item under `service`.
    ///
    /// Factory reset uses this centralized path so recognized test hosts and
    /// keychain-free proof processes cannot bypass the process disable gate
    /// through a direct `SecItemDelete` call.
    static func deleteAllItems(service: String) -> KeychainMutationOutcome {
        let access = currentBackend()
        if !access.bypassesDisableGate, access.isDisabled() { return .disabled }
        return onWriteQueueSync {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
            ]
            guard let status = performBackendOperation(access: access, operation: {
                access.backend.delete(query: query)
            }) else { return .disabled }
            if status == errSecSuccess || status == errSecItemNotFound { return .success }
            logFailure("delete-all", service: service, status: status)
            return mutationOutcome(for: status)
        }
    }

    /// Every attribute dictionary stored under `service`, de-duplicated on
    /// account name, with an authoritative flag for cache decisions.
    static func fetchAllItems(service: String, returnData: Bool) -> KeychainEnumerationOutcome {
        let access = currentBackend()
        if !access.bypassesDisableGate, access.isDisabled() {
            return KeychainEnumerationOutcome(items: [], status: errSecSuccess, isDefinitive: true)
        }
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnAttributes as String: true,
            kSecUseAuthenticationUI as String: kSecUseAuthenticationUISkip,
            kSecUseAuthenticationContext as String: KeychainQueryHelpers.nonInteractiveContext(),
        ]
        if returnData { query[kSecReturnData as String] = true }

        guard let (status, result) = performBackendOperation(access: access, operation: {
            access.backend.copyMatching(query)
        }) else {
            return KeychainEnumerationOutcome(
                items: [], status: errSecSuccess, isDefinitive: true
            )
        }
        if status == errSecItemNotFound {
            return KeychainEnumerationOutcome(items: [], status: status, isDefinitive: true)
        }
        guard status == errSecSuccess, let items = result as? [[String: Any]] else {
            logFailure("enumerate", service: service, status: status)
            return KeychainEnumerationOutcome(items: [], status: status, isDefinitive: false)
        }

        var merged: [String: [String: Any]] = [:]
        for item in items {
            guard let account = item[kSecAttrAccount as String] as? String else { continue }
            merged[account] = item
        }
        return KeychainEnumerationOutcome(
            items: Array(merged.values), status: status, isDefinitive: true)
    }

    // MARK: - Legacy-compatible CRUD
    //
    // Bool/Data views over the typed outcomes, kept so existing call sites
    // stay source-compatible. New code that needs to distinguish absence from
    // unavailability should use the `*Item(s)` variants above.

    /// Upsert `data` for (`service`, `account`).
    @discardableResult
    static func write(
        service: String,
        account: String,
        data: Data,
        accessible: CFString = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
    ) -> Bool {
        writeItem(service: service, account: account, data: data, accessible: accessible).isSuccess
    }

    /// Fire-and-forget variant of `write` that runs the blocking SecItem call
    /// off the caller's thread. Use when the authoritative value is held in
    /// memory and the write result isn't needed synchronously, so the caller
    /// never blocks the main thread on Security-framework I/O. `data` is
    /// captured at call time, so callers can encode their snapshot first and
    /// return immediately. Drained by `flushPendingWrites` at quit.
    static func writeInBackground(
        service: String,
        account: String,
        data: Data,
        accessible: CFString = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
    ) {
        let access = testBackendOverride
        let accessibility = accessible as String
        writeQueue.async {
            $testBackendOverride.withValue(access) {
                _ = writeItem(
                    service: service,
                    account: account,
                    data: data,
                    accessible: accessibility as CFString
                )
            }
        }
    }

    /// Run an arbitrary batch of keychain mutations on the serial write queue.
    /// For callers that need several dependent operations (e.g. save one item,
    /// delete another) to stay ordered relative to `writeInBackground` writes
    /// while keeping the blocking SecItem calls off the main thread.
    static func performInBackground(_ work: @escaping @Sendable () -> Void) {
        let access = testBackendOverride
        writeQueue.async {
            $testBackendOverride.withValue(access, operation: work)
        }
    }

    /// Await a keychain operation on the serial write queue and return its
    /// result. For callers (typically UI flows) that need the outcome of a
    /// SecItem read or mutation without blocking the main thread on
    /// Security-framework I/O. Ordered relative to `writeInBackground` and
    /// `performInBackground` work.
    static func perform<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        let access = testBackendOverride
        return await withCheckedContinuation { continuation in
            writeQueue.async {
                let result = $testBackendOverride.withValue(access, operation: work)
                continuation.resume(returning: result)
            }
        }
    }

    /// Await a blocking Keychain read on the concurrent read executor.
    ///
    /// The injected backend is captured before the DispatchQueue hop and
    /// restored only for this operation. This preserves test/live-proof
    /// isolation without putting independent reads behind the mutation queue.
    static func performRead<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        let access = testBackendOverride
        return await withCheckedContinuation { continuation in
            readQueue.async {
                let result = $testBackendOverride.withValue(access, operation: work)
                continuation.resume(returning: result)
            }
        }
    }

    /// Read (`service`, `account`). Returns `nil` when the item is absent or
    /// the read would require interactive authorization.
    static func read(service: String, account: String) -> Data? {
        readItem(service: service, account: account).data
    }

    /// Delete (`service`, `account`). In disabled test/live-proof mode the
    /// delete is a no-op that reports success, matching the wrapper contract.
    @discardableResult
    static func delete(service: String, account: String) -> Bool {
        let outcome = deleteItem(service: service, account: account)
        if outcome == .disabled { return true }
        return outcome.isSuccess
    }

    /// Every attribute dictionary stored under `service`, de-duplicated on
    /// account name.
    static func fetchAll(service: String, returnData: Bool) -> [[String: Any]] {
        fetchAllItems(service: service, returnData: returnData).items
    }

    /// Account names stored under `service`.
    static func allAccounts(service: String) -> [String] {
        fetchAll(service: service, returnData: false)
            .compactMap { $0[kSecAttrAccount as String] as? String }
    }
}
