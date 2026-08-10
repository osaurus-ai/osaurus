//
//  RemoteProviderKeychainIsolationTests.swift
//  OsaurusCoreTests
//
//  Proves that queued provider Keychain work carries only the scoped fake
//  backend, not the process's real Security.framework access.
//

import Foundation
import Security
import Testing

@testable import OsaurusCore

private final class RemoteProviderRecordingBackend: KeychainBackend, @unchecked Sendable {
    private let lock = NSLock()
    private var store: [String: Data] = [:]
    private var recordedOperations: [String] = []

    var operations: [String] {
        lock.lock()
        defer { lock.unlock() }
        return recordedOperations
    }

    func seed(service: String, account: String, data: Data) {
        lock.lock()
        store[key(service: service, account: account)] = data
        lock.unlock()
    }

    func value(service: String, account: String) -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return store[key(service: service, account: account)]
    }

    func copyMatching(_ query: [String: Any]) -> (status: OSStatus, result: AnyObject?) {
        lock.lock()
        defer { lock.unlock() }
        recordedOperations.append("copy")
        guard let data = store[key(for: query)] else {
            return (errSecItemNotFound, nil)
        }
        return (errSecSuccess, data as AnyObject)
    }

    func update(query: [String: Any], attributes: [String: Any]) -> OSStatus {
        lock.lock()
        defer { lock.unlock() }
        recordedOperations.append("update")
        let itemKey = key(for: query)
        guard store[itemKey] != nil else { return errSecItemNotFound }
        if let data = attributes[kSecValueData as String] as? Data {
            store[itemKey] = data
        }
        return errSecSuccess
    }

    func add(attributes: [String: Any]) -> OSStatus {
        lock.lock()
        defer { lock.unlock() }
        recordedOperations.append("add")
        let itemKey = key(for: attributes)
        guard store[itemKey] == nil else { return errSecDuplicateItem }
        store[itemKey] = attributes[kSecValueData as String] as? Data
        return errSecSuccess
    }

    func delete(query: [String: Any]) -> OSStatus {
        lock.lock()
        defer { lock.unlock() }
        recordedOperations.append("delete")
        return store.removeValue(forKey: key(for: query)) == nil
            ? errSecItemNotFound
            : errSecSuccess
    }

    private func key(service: String, account: String) -> String {
        "\(service)\u{0}\(account)"
    }

    private func key(for query: [String: Any]) -> String {
        key(
            service: query[kSecAttrService as String] as? String ?? "",
            account: query[kSecAttrAccount as String] as? String ?? ""
        )
    }
}

private final class BlockingRemoteProviderReadBackend: KeychainBackend, @unchecked Sendable {
    private let readStarted = DispatchSemaphore(value: 0)
    private let readRelease = DispatchSemaphore(value: 0)
    private let value: Data

    init(value: Data) {
        self.value = value
    }

    func waitForReadToStart(timeout: TimeInterval) -> Bool {
        readStarted.wait(timeout: .now() + timeout) == .success
    }

    func releaseRead() {
        readRelease.signal()
    }

    func copyMatching(_ query: [String: Any]) -> (status: OSStatus, result: AnyObject?) {
        readStarted.signal()
        readRelease.wait()
        return (errSecSuccess, value as AnyObject)
    }

    func update(query: [String: Any], attributes: [String: Any]) -> OSStatus {
        errSecItemNotFound
    }

    func add(attributes: [String: Any]) -> OSStatus {
        errSecSuccess
    }

    func delete(query: [String: Any]) -> OSStatus {
        errSecSuccess
    }
}

private final class ConcurrentRemoteProviderReadBackend: KeychainBackend, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]
    private let blockedAccount: String
    private let blockedReadStarted = DispatchSemaphore(value: 0)
    private let blockedReadRelease = DispatchSemaphore(value: 0)
    private let fastReadCompleted = DispatchSemaphore(value: 0)

    init(blockedAccount: String) {
        self.blockedAccount = blockedAccount
    }

    func seed(account: String, value: Data) {
        lock.lock()
        values[account] = value
        lock.unlock()
    }

    func waitForBlockedReadToStart(timeout: TimeInterval) -> Bool {
        blockedReadStarted.wait(timeout: .now() + timeout) == .success
    }

    func releaseBlockedRead() {
        blockedReadRelease.signal()
    }

    func waitForFastReadToComplete(timeout: TimeInterval) -> Bool {
        fastReadCompleted.wait(timeout: .now() + timeout) == .success
    }

    func copyMatching(_ query: [String: Any]) -> (status: OSStatus, result: AnyObject?) {
        let account = query[kSecAttrAccount as String] as? String ?? ""
        if account == blockedAccount {
            blockedReadStarted.signal()
            blockedReadRelease.wait()
        } else {
            fastReadCompleted.signal()
        }

        lock.lock()
        defer { lock.unlock() }
        guard let value = values[account] else {
            return (errSecItemNotFound, nil)
        }
        return (errSecSuccess, value as AnyObject)
    }

    func update(query: [String: Any], attributes: [String: Any]) -> OSStatus {
        errSecItemNotFound
    }

    func add(attributes: [String: Any]) -> OSStatus {
        errSecSuccess
    }

    func delete(query: [String: Any]) -> OSStatus {
        errSecSuccess
    }
}

private final class OrderedMutationBackend: KeychainBackend, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]
    private var recordedOperations: [String] = []
    private var didBlockFirstAdd = false
    private let firstAddStarted = DispatchSemaphore(value: 0)
    private let firstAddRelease = DispatchSemaphore(value: 0)

    var operations: [String] {
        lock.lock()
        defer { lock.unlock() }
        return recordedOperations
    }

    func waitForFirstAddToStart(timeout: TimeInterval) -> Bool {
        firstAddStarted.wait(timeout: .now() + timeout) == .success
    }

    func releaseFirstAdd() {
        firstAddRelease.signal()
    }

    func copyMatching(_ query: [String: Any]) -> (status: OSStatus, result: AnyObject?) {
        (errSecItemNotFound, nil)
    }

    func update(query: [String: Any], attributes: [String: Any]) -> OSStatus {
        let account = query[kSecAttrAccount as String] as? String ?? ""
        lock.lock()
        recordedOperations.append("update:\(account)")
        lock.unlock()
        return errSecItemNotFound
    }

    func add(attributes: [String: Any]) -> OSStatus {
        let account = attributes[kSecAttrAccount as String] as? String ?? ""
        lock.lock()
        recordedOperations.append("add:\(account)")
        let shouldBlock = !didBlockFirstAdd
        didBlockFirstAdd = true
        lock.unlock()

        if shouldBlock {
            firstAddStarted.signal()
            firstAddRelease.wait()
        }

        lock.lock()
        values[account] = attributes[kSecValueData as String] as? Data
        lock.unlock()
        return errSecSuccess
    }

    func delete(query: [String: Any]) -> OSStatus {
        errSecSuccess
    }
}

private actor AsyncCompletionFlag {
    private var completed = false

    func markCompleted() {
        completed = true
    }

    func isCompleted() -> Bool {
        completed
    }
}

private func waitForCompletion(
    _ flag: AsyncCompletionFlag,
    timeoutNanoseconds: UInt64
) async -> Bool {
    let deadline = DispatchTime.now().uptimeNanoseconds + timeoutNanoseconds
    while !(await flag.isCompleted()) {
        if DispatchTime.now().uptimeNanoseconds >= deadline {
            return false
        }
        try? await Task.sleep(nanoseconds: 1_000_000)
    }
    return true
}

@Suite("Remote provider Keychain isolation", .serialized)
struct RemoteProviderKeychainIsolationTests {
    private static let service = "ai.osaurus.remote"

    @Test("queued provider reads and deletes use the injected backend in disabled mode")
    func queuedProviderReadsAndDeletesUseScopedBackend() async throws {
        try #require(KeychainQueryHelpers.disablesKeychainForProcess)

        let providerId = UUID()
        let account = "\(providerId.uuidString).apiKey"
        let backend = RemoteProviderRecordingBackend()
        backend.seed(service: Self.service, account: account, data: Data("queued-secret".utf8))

        let unscopedRead = await RemoteProviderKeychain.runOffCooperativeExecutor {
            RemoteProviderKeychain.getAPIKey(for: providerId)
        }
        let unscopedDelete = await RemoteProviderKeychain.runOffCooperativeExecutor {
            RemoteProviderKeychain.deleteAPIKey(for: providerId)
        }

        let result = await Keychain._withBackendForTesting(backend) {
            let value = await RemoteProviderKeychain.runOffCooperativeExecutor {
                RemoteProviderKeychain.getAPIKey(for: providerId)
            }
            let unrelatedValue = await Task.detached {
                await RemoteProviderKeychain.runOffCooperativeExecutor {
                    RemoteProviderKeychain.getAPIKey(for: providerId)
                }
            }.value
            let deleted = await RemoteProviderKeychain.runOffCooperativeExecutor {
                RemoteProviderKeychain.deleteAPIKey(for: providerId)
            }
            return (value, unrelatedValue, deleted)
        }

        #expect(unscopedRead == nil)
        #expect(unscopedDelete)
        #expect(result.0 == "queued-secret")
        #expect(result.1 == nil)
        #expect(result.2)
        #expect(backend.value(service: Self.service, account: account) == nil)
        #expect(backend.operations == ["copy", "delete"])
    }

    @Test("a blocked provider read does not delay the mutation flush")
    func blockedProviderReadDoesNotDelayMutationFlush() async throws {
        try #require(KeychainQueryHelpers.disablesKeychainForProcess)

        let providerId = UUID()
        let backend = BlockingRemoteProviderReadBackend(value: Data("queued-secret".utf8))
        let read = Task {
            await Keychain._withBackendForTesting(backend) {
                await RemoteProviderKeychain.runOffCooperativeExecutor {
                    RemoteProviderKeychain.getAPIKey(for: providerId)
                }
            }
        }

        guard backend.waitForReadToStart(timeout: 2) else {
            backend.releaseRead()
            _ = await read.value
            Issue.record("provider read did not enter the Keychain queue")
            return
        }

        // The production quit path uses the same API with a three-second
        // budget. A read must not occupy the mutation queue, so the flush can
        // complete even while Security.framework is still answering it.
        #expect(Keychain.flushPendingWrites(timeout: 0.05))

        backend.releaseRead()
        #expect(await read.value == "queued-secret")
        #expect(Keychain.flushPendingWrites(timeout: 1))
    }

    @Test("an unrelated read completes while another provider read is blocked")
    func unrelatedReadCompletesWhileProviderReadIsBlocked() async throws {
        try #require(KeychainQueryHelpers.disablesKeychainForProcess)

        let blockedProviderId = UUID()
        let fastProviderId = UUID()
        let blockedAccount = "\(blockedProviderId.uuidString).apiKey"
        let backend = ConcurrentRemoteProviderReadBackend(blockedAccount: blockedAccount)
        backend.seed(account: blockedAccount, value: Data("blocked".utf8))
        backend.seed(
            account: "\(fastProviderId.uuidString).apiKey",
            value: Data("fast".utf8)
        )

        let blockedRead = Task {
            await Keychain._withBackendForTesting(backend) {
                await RemoteProviderKeychain.runOffCooperativeExecutor {
                    RemoteProviderKeychain.getAPIKey(for: blockedProviderId)
                }
            }
        }
        guard backend.waitForBlockedReadToStart(timeout: 2) else {
            backend.releaseBlockedRead()
            _ = await blockedRead.value
            Issue.record("blocked provider read did not enter the read executor")
            return
        }

        let fastRead = Task {
            await Keychain._withBackendForTesting(backend) {
                await RemoteProviderKeychain.runOffCooperativeExecutor {
                    RemoteProviderKeychain.getAPIKey(for: fastProviderId)
                }
            }
        }

        #expect(backend.waitForFastReadToComplete(timeout: 1))
        backend.releaseBlockedRead()
        #expect(await fastRead.value == "fast")
        #expect(await blockedRead.value == "blocked")
    }

    @Test("provider writes remain ordered on the mutation executor")
    func providerWritesRemainOrderedOnMutationExecutor() async throws {
        try #require(KeychainQueryHelpers.disablesKeychainForProcess)

        let firstProviderId = UUID()
        let secondProviderId = UUID()
        let first = RemoteProviderOAuthTokens(
            accessToken: "first-access",
            refreshToken: "first-refresh",
            expiresAt: Date(timeIntervalSince1970: 10),
            accountId: "first"
        )
        let second = RemoteProviderOAuthTokens(
            accessToken: "second-access",
            refreshToken: "second-refresh",
            expiresAt: Date(timeIntervalSince1970: 20),
            accountId: "second"
        )
        let backend = OrderedMutationBackend()

        let firstWrite = Task {
            await Keychain._withBackendForTesting(backend) {
                await RemoteProviderKeychain.saveOAuthTokensOffMainActor(first, for: firstProviderId)
            }
        }
        guard backend.waitForFirstAddToStart(timeout: 2) else {
            backend.releaseFirstAdd()
            _ = await firstWrite.value
            Issue.record("first provider mutation did not enter the mutation executor")
            return
        }

        let secondFinished = AsyncCompletionFlag()
        let secondWrite = Task {
            let result = await Keychain._withBackendForTesting(backend) {
                await RemoteProviderKeychain.saveOAuthTokensOffMainActor(second, for: secondProviderId)
            }
            await secondFinished.markCompleted()
            return result
        }

        #expect(!(await waitForCompletion(secondFinished, timeoutNanoseconds: 100_000_000)))
        #expect(backend.operations.count == 2)
        backend.releaseFirstAdd()

        #expect(await firstWrite.value)
        #expect(await secondWrite.value)
        #expect(backend.operations.count == 4)
        #expect(backend.operations[0].hasPrefix("update:"))
        #expect(backend.operations[1].hasPrefix("add:"))
        #expect(backend.operations[2].hasPrefix("update:"))
        #expect(backend.operations[3].hasPrefix("add:"))
    }
}
