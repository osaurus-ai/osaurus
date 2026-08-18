// Copyright © 2026 osaurus.

import Foundation
import LocalAuthentication
import Security
import OsaurusRepository
import Testing

@testable import OsaurusCore

/// Deterministic in-memory SecItem backend that records every operation, so
/// each `OSStatus` path in the shared `Keychain` helper can be exercised
/// without touching a real keychain.
private final class FakeKeychainBackend: KeychainBackend, @unchecked Sendable {
    private let lock = NSLock()
    private var store: [String: Data] = [:]

    /// Forced statuses; when nil, the in-memory store behaves like a healthy
    /// keychain.
    var updateStatus: OSStatus?
    var addStatus: OSStatus?
    var copyStatus: OSStatus?
    var deleteStatus: OSStatus?

    private var recordedOperations: [String] = []
    var operations: [String] {
        lock.lock()
        defer { lock.unlock() }
        return recordedOperations
    }

    private func itemKey(_ query: [String: Any]) -> String {
        let service = query[kSecAttrService as String] as? String ?? ""
        let account = query[kSecAttrAccount as String] as? String ?? ""
        return "\(service)\u{0}\(account)"
    }

    func value(service: String, account: String) -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return store["\(service)\u{0}\(account)"]
    }

    func seed(service: String, account: String, data: Data) {
        lock.lock()
        defer { lock.unlock() }
        store["\(service)\u{0}\(account)"] = data
    }

    func copyMatching(_ query: [String: Any]) -> (status: OSStatus, result: AnyObject?) {
        lock.lock()
        defer { lock.unlock() }
        recordedOperations.append("copy")
        if let forced = copyStatus { return (forced, nil) }

        let matchAll =
            (query[kSecMatchLimit as String] as? String) == (kSecMatchLimitAll as String)
        if matchAll {
            let service = query[kSecAttrService as String] as? String ?? ""
            let prefix = "\(service)\u{0}"
            let items: [[String: Any]] = store.compactMap { key, data in
                guard key.hasPrefix(prefix) else { return nil }
                var item: [String: Any] = [
                    kSecAttrAccount as String: String(key.dropFirst(prefix.count))
                ]
                if (query[kSecReturnData as String] as? Bool) == true {
                    item[kSecValueData as String] = data
                }
                return item
            }
            if items.isEmpty { return (errSecItemNotFound, nil) }
            return (errSecSuccess, items as AnyObject)
        }

        guard let data = store[itemKey(query)] else { return (errSecItemNotFound, nil) }
        return (errSecSuccess, data as AnyObject)
    }

    func update(query: [String: Any], attributes: [String: Any]) -> OSStatus {
        lock.lock()
        defer { lock.unlock() }
        recordedOperations.append("update")
        if let forced = updateStatus { return forced }
        let key = itemKey(query)
        guard store[key] != nil else { return errSecItemNotFound }
        if let data = attributes[kSecValueData as String] as? Data { store[key] = data }
        return errSecSuccess
    }

    func add(attributes: [String: Any]) -> OSStatus {
        lock.lock()
        defer { lock.unlock() }
        recordedOperations.append("add")
        if let forced = addStatus { return forced }
        let key = itemKey(attributes)
        guard store[key] == nil else { return errSecDuplicateItem }
        store[key] = attributes[kSecValueData as String] as? Data
        return errSecSuccess
    }

    func delete(query: [String: Any]) -> OSStatus {
        lock.lock()
        defer { lock.unlock() }
        recordedOperations.append("delete")
        if let forced = deleteStatus { return forced }
        if query[kSecAttrAccount as String] == nil {
            let service = query[kSecAttrService as String] as? String ?? ""
            let prefix = "\(service)\u{0}"
            let matchingKeys = store.keys.filter { $0.hasPrefix(prefix) }
            for key in matchingKeys { store.removeValue(forKey: key) }
            return matchingKeys.isEmpty ? errSecItemNotFound : errSecSuccess
        }
        guard store.removeValue(forKey: itemKey(query)) != nil else { return errSecItemNotFound }
        return errSecSuccess
    }
}

private final class AuthenticationContextCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [LAContext] = []

    func append(_ context: LAContext) {
        lock.lock()
        storage.append(context)
        lock.unlock()
    }

    var contexts: [LAContext] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

private final class KeychainIsolationTransitionProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var disabled = false
    private var checks = 0
    let firstCheck = DispatchSemaphore(value: 0)

    func isDisabled() -> Bool {
        lock.lock()
        checks += 1
        let shouldSignal = checks == 1
        let result = disabled
        lock.unlock()
        if shouldSignal { firstCheck.signal() }
        return result
    }

    func disable() {
        lock.withLock { disabled = true }
    }
}

private final class KeychainMutationOutcomeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: KeychainMutationOutcome?

    func set(_ outcome: KeychainMutationOutcome) {
        lock.withLock { storage = outcome }
    }

    var value: KeychainMutationOutcome? {
        lock.withLock { storage }
    }
}

@Suite("Keychain typed outcomes", .serialized)
struct KeychainTests {
    private static let service = "ai.osaurus.test.keychain"

    private func withFakeBackend<T>(
        _ backend: FakeKeychainBackend, _ body: () throws -> T
    ) rethrows -> T {
        try Keychain._withBackendForTesting(backend, operation: body)
    }

    // MARK: - Write

    @Test("noninteractive authentication contexts are cached per thread")
    func nonInteractiveContextsAreThreadConfined() {
        let current = KeychainQueryHelpers.nonInteractiveContext()
        #expect(KeychainQueryHelpers.nonInteractiveContext() === current)
        #expect(current.interactionNotAllowed)

        let collector = AuthenticationContextCollector()
        let group = DispatchGroup()
        for _ in 0 ..< 2 {
            group.enter()
            Thread.detachNewThread {
                let context = KeychainQueryHelpers.nonInteractiveContext()
                collector.append(context)
                group.leave()
            }
        }

        #expect(group.wait(timeout: .now() + 2) == .success)
        let contexts = collector.contexts
        let identifiers = contexts.map(ObjectIdentifier.init)
        #expect(contexts.count == 2)
        #expect(contexts.allSatisfy { $0.interactionNotAllowed })
        #expect(Set(identifiers).count == 2)
        #expect(!identifiers.contains(ObjectIdentifier(current)))
    }

    @Test("write updates an existing item without adding or deleting")
    func writeUpdatesExistingItem() {
        let backend = FakeKeychainBackend()
        backend.seed(service: Self.service, account: "a", data: Data("old".utf8))
        withFakeBackend(backend) {
            let outcome = Keychain.writeItem(
                service: Self.service, account: "a", data: Data("new".utf8))
            #expect(outcome == .success)
        }
        #expect(backend.value(service: Self.service, account: "a") == Data("new".utf8))
        #expect(backend.operations == ["update"])
    }

    @Test("delete-all removes one service without touching another")
    func deleteAllIsServiceScoped() {
        let backend = FakeKeychainBackend()
        backend.seed(service: Self.service, account: "a", data: Data("a".utf8))
        backend.seed(service: Self.service, account: "b", data: Data("b".utf8))
        backend.seed(service: "ai.osaurus.test.other", account: "a", data: Data("other".utf8))

        withFakeBackend(backend) {
            #expect(Keychain.deleteAllItems(service: Self.service) == .success)
        }

        #expect(backend.value(service: Self.service, account: "a") == nil)
        #expect(backend.value(service: Self.service, account: "b") == nil)
        #expect(
            backend.value(service: "ai.osaurus.test.other", account: "a")
                == Data("other".utf8)
        )
        #expect(backend.operations == ["delete"])
    }

    @Test("write adds only after errSecItemNotFound")
    func writeAddsOnlyAfterNotFound() {
        let backend = FakeKeychainBackend()
        withFakeBackend(backend) {
            let outcome = Keychain.writeItem(
                service: Self.service, account: "a", data: Data("v".utf8))
            #expect(outcome == .success)
        }
        #expect(backend.value(service: Self.service, account: "a") == Data("v".utf8))
        #expect(backend.operations == ["update", "add"])
    }

    @Test("a non-not-found, non-denied update failure is surfaced, not hidden behind an add")
    func writeSurfacesUpdateFailureWithoutAdding() {
        let backend = FakeKeychainBackend()
        backend.seed(service: Self.service, account: "a", data: Data("old".utf8))
        backend.updateStatus = errSecParam
        withFakeBackend(backend) {
            let outcome = Keychain.writeItem(
                service: Self.service, account: "a", data: Data("new".utf8))
            #expect(outcome == .failure(errSecParam))
        }
        // The add path must not run: it would report errSecDuplicateItem and
        // mask the real error. The stored value must survive untouched.
        #expect(backend.operations == ["update"])
        #expect(backend.value(service: Self.service, account: "a") == Data("old".utf8))
    }

    @Test("write maps unavailable and generic statuses to typed outcomes")
    func writeMapsStatuses() {
        let cases: [(OSStatus, KeychainMutationOutcome)] = [
            (errSecInteractionNotAllowed, .unavailable(errSecInteractionNotAllowed)),
            (errSecNotAvailable, .unavailable(errSecNotAvailable)),
            (errSecParam, .failure(errSecParam)),
        ]
        for (status, expected) in cases {
            let backend = FakeKeychainBackend()
            backend.seed(service: Self.service, account: "a", data: Data("old".utf8))
            backend.updateStatus = status
            withFakeBackend(backend) {
                let outcome = Keychain.writeItem(
                    service: Self.service, account: "a", data: Data("new".utf8))
                #expect(outcome == expected, "status \(status)")
            }
        }
    }

    @Test("an ACL-denied update recovers by deleting and re-adding the item")
    func writeRecoversFromDeniedUpdate() {
        // An access-denied update means the existing item was written by a
        // differently signed build and is unreadable to this process anyway,
        // so write reclaims the account with delete + add.
        let backend = FakeKeychainBackend()
        backend.seed(service: Self.service, account: "a", data: Data("orphaned".utf8))
        backend.updateStatus = errSecAuthFailed
        withFakeBackend(backend) {
            let outcome = Keychain.writeItem(
                service: Self.service, account: "a", data: Data("new".utf8))
            #expect(outcome == .success)
        }
        #expect(backend.operations == ["update", "delete", "add"])
        #expect(backend.value(service: Self.service, account: "a") == Data("new".utf8))
    }

    @Test("a denied update whose recovery delete fails reports the original denial")
    func writeDeniedRecoveryDeleteFailure() {
        let backend = FakeKeychainBackend()
        backend.seed(service: Self.service, account: "a", data: Data("orphaned".utf8))
        backend.updateStatus = errSecAuthFailed
        backend.deleteStatus = errSecAuthFailed
        withFakeBackend(backend) {
            let outcome = Keychain.writeItem(
                service: Self.service, account: "a", data: Data("new".utf8))
            #expect(outcome == .accessDenied(errSecAuthFailed))
        }
        // The add path must not run after a failed delete: the orphaned item
        // still owns the account and an add would just report a duplicate.
        #expect(backend.operations == ["update", "delete"])
        #expect(backend.value(service: Self.service, account: "a") == Data("orphaned".utf8))
    }

    @Test("write never deletes outside denied-update recovery")
    func writeNeverDeletes() {
        let backend = FakeKeychainBackend()
        backend.seed(service: Self.service, account: "a", data: Data("old".utf8))
        withFakeBackend(backend) {
            _ = Keychain.writeItem(service: Self.service, account: "a", data: Data("v1".utf8))
            _ = Keychain.writeItem(service: Self.service, account: "b", data: Data("v2".utf8))
        }
        #expect(!backend.operations.contains("delete"))
    }

    @Test("legacy Bool write reflects the typed outcome")
    func legacyWriteReflectsOutcome() {
        let ok = FakeKeychainBackend()
        withFakeBackend(ok) {
            #expect(Keychain.write(service: Self.service, account: "a", data: Data("v".utf8)))
        }
        let broken = FakeKeychainBackend()
        broken.updateStatus = errSecItemNotFound
        broken.addStatus = errSecNotAvailable
        withFakeBackend(broken) {
            #expect(!Keychain.write(service: Self.service, account: "a", data: Data("v".utf8)))
        }
    }

    // MARK: - Read

    @Test("read distinguishes found, not-found, unavailable, denied, and failure")
    func readMapsStatuses() {
        let backend = FakeKeychainBackend()
        backend.seed(service: Self.service, account: "present", data: Data("v".utf8))
        withFakeBackend(backend) {
            #expect(
                Keychain.readItem(service: Self.service, account: "present")
                    == .found(Data("v".utf8)))
            #expect(Keychain.readItem(service: Self.service, account: "absent") == .notFound)
        }

        let statuses: [(OSStatus, KeychainReadOutcome)] = [
            (errSecInteractionNotAllowed, .unavailable(errSecInteractionNotAllowed)),
            (errSecNotAvailable, .unavailable(errSecNotAvailable)),
            (errSecAuthFailed, .accessDenied(errSecAuthFailed)),
            (errSecUserCanceled, .accessDenied(errSecUserCanceled)),
            (errSecParam, .failure(errSecParam)),
        ]
        for (status, expected) in statuses {
            let failing = FakeKeychainBackend()
            failing.copyStatus = status
            withFakeBackend(failing) {
                let outcome = Keychain.readItem(service: Self.service, account: "a")
                #expect(outcome == expected, "status \(status)")
                #expect(!outcome.isDefinitive, "status \(status) must not be cacheable")
            }
        }
    }

    @Test("only found/not-found read outcomes are definitive")
    func readDefinitiveness() {
        #expect(KeychainReadOutcome.found(Data()).isDefinitive)
        #expect(KeychainReadOutcome.notFound.isDefinitive)
        #expect(KeychainReadOutcome.disabled.isDefinitive)
        #expect(!KeychainReadOutcome.unavailable(errSecInteractionNotAllowed).isDefinitive)
        #expect(!KeychainReadOutcome.accessDenied(errSecAuthFailed).isDefinitive)
        #expect(!KeychainReadOutcome.failure(errSecParam).isDefinitive)
    }

    @Test("legacy read returns data only when found")
    func legacyReadReturnsDataOnlyWhenFound() {
        let backend = FakeKeychainBackend()
        backend.seed(service: Self.service, account: "a", data: Data("v".utf8))
        withFakeBackend(backend) {
            #expect(Keychain.read(service: Self.service, account: "a") == Data("v".utf8))
            #expect(Keychain.read(service: Self.service, account: "missing") == nil)
        }
        let locked = FakeKeychainBackend()
        locked.copyStatus = errSecInteractionNotAllowed
        withFakeBackend(locked) {
            #expect(Keychain.read(service: Self.service, account: "a") == nil)
        }
    }

    // MARK: - Delete

    @Test("delete treats a missing item as success and surfaces real failures")
    func deleteOutcomes() {
        let backend = FakeKeychainBackend()
        backend.seed(service: Self.service, account: "a", data: Data("v".utf8))
        withFakeBackend(backend) {
            #expect(Keychain.deleteItem(service: Self.service, account: "a") == .success)
            #expect(Keychain.deleteItem(service: Self.service, account: "a") == .success)
        }

        let failing = FakeKeychainBackend()
        failing.deleteStatus = errSecInteractionNotAllowed
        withFakeBackend(failing) {
            #expect(
                Keychain.deleteItem(service: Self.service, account: "a")
                    == .unavailable(errSecInteractionNotAllowed))
        }
    }

    // MARK: - Enumeration

    @Test("enumeration is definitive on success and empty service")
    func enumerationDefinitive() {
        let backend = FakeKeychainBackend()
        backend.seed(service: Self.service, account: "a", data: Data("1".utf8))
        backend.seed(service: Self.service, account: "b", data: Data("2".utf8))
        withFakeBackend(backend) {
            let outcome = Keychain.fetchAllItems(service: Self.service, returnData: false)
            #expect(outcome.isDefinitive)
            #expect(
                Set(Keychain.allAccounts(service: Self.service)) == ["a", "b"])
            let empty = Keychain.fetchAllItems(service: "ai.osaurus.test.empty", returnData: false)
            #expect(empty.isDefinitive)
            #expect(empty.items.isEmpty)
        }
    }

    @Test("a transient enumeration failure is not definitive (never cache it)")
    func enumerationTransientFailureNotDefinitive() {
        let backend = FakeKeychainBackend()
        backend.copyStatus = errSecInteractionNotAllowed
        withFakeBackend(backend) {
            let outcome = Keychain.fetchAllItems(service: Self.service, returnData: false)
            #expect(!outcome.isDefinitive)
            #expect(outcome.items.isEmpty)
        }
    }

    // MARK: - Queue draining

    @Test("flushPendingWrites drains background writes")
    func flushDrainsBackgroundWrites() {
        let backend = FakeKeychainBackend()
        withFakeBackend(backend) {
            Keychain.writeInBackground(
                service: Self.service, account: "bg", data: Data("queued".utf8))
            Keychain.flushPendingWrites()
        }
        #expect(backend.value(service: Self.service, account: "bg") == Data("queued".utf8))
    }

    @Test("mutations inside performInBackground batches do not deadlock")
    func performInBackgroundReentrancy() {
        let backend = FakeKeychainBackend()
        withFakeBackend(backend) {
            Keychain.performInBackground {
                _ = Keychain.writeItem(
                    service: Self.service, account: "nested", data: Data("v".utf8))
                _ = Keychain.deleteItem(service: Self.service, account: "other")
            }
            Keychain.flushPendingWrites()
        }
        #expect(backend.value(service: Self.service, account: "nested") == Data("v".utf8))
    }

    @Test("backend overrides stay isolated across concurrent test tasks")
    func backendOverridesAreTaskScoped() async {
        let first = FakeKeychainBackend()
        let second = FakeKeychainBackend()
        let barrier = PairBarrier()

        async let firstOutcome = Keychain._withBackendForTesting(first) {
            await barrier.wait()
            await Task.yield()
            return Keychain.writeItem(
                service: Self.service, account: "first", data: Data("a".utf8))
        }
        async let secondOutcome = Keychain._withBackendForTesting(second) {
            await barrier.wait()
            await Task.yield()
            return Keychain.writeItem(
                service: Self.service, account: "second", data: Data("b".utf8))
        }

        let outcomes = await (firstOutcome, secondOutcome)
        #expect(outcomes.0 == .success)
        #expect(outcomes.1 == .success)
        #expect(first.value(service: Self.service, account: "first") == Data("a".utf8))
        #expect(first.value(service: Self.service, account: "second") == nil)
        #expect(second.value(service: Self.service, account: "second") == Data("b".utf8))
        #expect(second.value(service: Self.service, account: "first") == nil)
    }

    @Test("detached tasks cannot escape a disabled host through a fake backend scope")
    func detachedTasksDoNotReachRealKeychain() async throws {
        try #require(ProcessDataRootPolicy.isRecognizedTestHostProcess)
        try #require(KeychainQueryHelpers.disablesKeychainForProcess)

        let backend = FakeKeychainBackend()
        let service = Self.service
        let outcomes = await Keychain._withBackendForTesting(backend) {
            #expect(Keychain.hasInjectedBackendForCurrentContext)
            let scopedOutcome = Keychain.writeItem(
                service: service, account: "scoped", data: Data("fake".utf8))
            let detachedOutcome = await Task.detached {
                let hasInjectedBackend = Keychain.hasInjectedBackendForCurrentContext
                let outcome = Keychain.writeItem(
                    service: service, account: "detached", data: Data("real".utf8))
                return (hasInjectedBackend, outcome)
            }.value
            return (scopedOutcome, detachedOutcome.0, detachedOutcome.1)
        }

        #expect(outcomes.0 == .success)
        #expect(!outcomes.1)
        #expect(outcomes.2 == .disabled)
        #expect(backend.value(service: Self.service, account: "scoped") == Data("fake".utf8))
        #expect(backend.value(service: Self.service, account: "detached") == nil)
        #expect(backend.operations == ["update", "add"])
    }

    @Test("synchronous writes are ordered relative to queued background work")
    func syncWritesAreOrderedWithQueue() {
        let backend = FakeKeychainBackend()
        withFakeBackend(backend) {
            Keychain.writeInBackground(
                service: Self.service, account: "ordered", data: Data("first".utf8))
            // The synchronous write joins the same serial queue, so it must
            // observe (and overwrite) the queued value, never lose to it.
            _ = Keychain.writeItem(
                service: Self.service, account: "ordered", data: Data("second".utf8))
        }
        #expect(backend.value(service: Self.service, account: "ordered") == Data("second".utf8))
    }

    @Test("queued production writes recheck isolation before backend execution")
    func queuedWriteRechecksIsolationAtExecution() {
        let blockerEntered = DispatchSemaphore(value: 0)
        let releaseBlocker = DispatchSemaphore(value: 0)
        Keychain.performInBackground {
            blockerEntered.signal()
            releaseBlocker.wait()
        }
        guard blockerEntered.wait(timeout: .now() + 2) == .success else {
            Issue.record("Keychain write queue blocker was not admitted")
            releaseBlocker.signal()
            return
        }

        let backend = FakeKeychainBackend()
        let gate = KeychainIsolationTransitionProbe()
        let outcome = KeychainMutationOutcomeBox()
        let completed = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Keychain._withBackendForTesting(
                backend,
                bypassesDisableGate: false,
                isDisabled: { gate.isDisabled() }
            ) {
                Keychain.writeItem(
                    service: Self.service,
                    account: "transition",
                    data: Data("must-not-write".utf8)
                )
            }
            outcome.set(result)
            completed.signal()
        }

        guard gate.firstCheck.wait(timeout: .now() + 2) == .success else {
            Issue.record("Queued write did not pass its admission check")
            releaseBlocker.signal()
            return
        }
        gate.disable()
        releaseBlocker.signal()

        #expect(completed.wait(timeout: .now() + 2) == .success)
        #expect(outcome.value == .disabled)
        #expect(backend.operations.isEmpty)
    }

    // MARK: - Disabled mode

    @Test("disabled mode short-circuits every operation without backend calls")
    func disabledModeShortCircuits() {
        // Only meaningful when the process-level disable gate is active (the
        // documented test environment sets OSAURUS_DISABLE_KEYCHAIN_FOR_TESTS=1).
        guard KeychainQueryHelpers.disablesKeychainForProcess else { return }
        // No backend override installed: the gate must win before SecItem.
        #expect(Keychain.readItem(service: Self.service, account: "a") == .disabled)
        #expect(Keychain.read(service: Self.service, account: "a") == nil)
        #expect(
            Keychain.writeItem(service: Self.service, account: "a", data: Data("v".utf8))
                == .disabled)
        #expect(!Keychain.write(service: Self.service, account: "a", data: Data("v".utf8)))
        #expect(Keychain.deleteItem(service: Self.service, account: "a") == .disabled)
        #expect(Keychain.delete(service: Self.service, account: "a"))
        let enumeration = Keychain.fetchAllItems(service: Self.service, returnData: false)
        #expect(enumeration.isDefinitive)
        #expect(enumeration.items.isEmpty)
    }

    @Test("a test backend override bypasses the disable gate")
    func overrideBypassesDisableGate() {
        let backend = FakeKeychainBackend()
        withFakeBackend(backend) {
            #expect(Keychain.write(service: Self.service, account: "a", data: Data("v".utf8)))
            #expect(Keychain.read(service: Self.service, account: "a") == Data("v".utf8))
        }
    }
}

private actor PairBarrier {
    private var waiter: CheckedContinuation<Void, Never>?

    func wait() async {
        if let waiter {
            self.waiter = nil
            waiter.resume()
            return
        }
        await withCheckedContinuation { waiter = $0 }
    }
}
