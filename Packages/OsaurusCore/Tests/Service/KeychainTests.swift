// Copyright © 2026 osaurus.

import Foundation
import Security
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
        guard store.removeValue(forKey: itemKey(query)) != nil else { return errSecItemNotFound }
        return errSecSuccess
    }
}

/// The backend override is process-global, so these tests must not interleave.
@Suite("Keychain typed outcomes", .serialized)
struct KeychainTests {
    private static let service = "ai.osaurus.test.keychain"

    private func withFakeBackend<T>(
        _ backend: FakeKeychainBackend, _ body: () throws -> T
    ) rethrows -> T {
        Keychain._setBackendForTesting(backend)
        defer { Keychain._setBackendForTesting(nil) }
        return try body()
    }

    // MARK: - Write

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

    @Test("a non-not-found update failure is surfaced, not hidden behind an add")
    func writeSurfacesUpdateFailureWithoutAdding() {
        let backend = FakeKeychainBackend()
        backend.seed(service: Self.service, account: "a", data: Data("old".utf8))
        backend.updateStatus = errSecAuthFailed
        withFakeBackend(backend) {
            let outcome = Keychain.writeItem(
                service: Self.service, account: "a", data: Data("new".utf8))
            #expect(outcome == .accessDenied(errSecAuthFailed))
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
            (errSecAuthFailed, .accessDenied(errSecAuthFailed)),
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

    @Test("write never deletes (so it cannot wipe the item it just wrote)")
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
