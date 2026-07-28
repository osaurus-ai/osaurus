//
//  TemporaryPairedKeyStoreTests.swift
//  OsaurusCoreTests
//
//  Crash-safe temporary Bonjour pairing tracking.
//  Uses in-memory persistence / recording deleters so tests never touch the
//  login Keychain or raise biometric prompts.
//

import Foundation
import Testing

@testable import OsaurusCore

// MARK: - Test seams

private final class InMemoryTemporaryPairedKeyPersistence:
    TemporaryPairedKeyPersisting, @unchecked Sendable
{
    private let lock = NSLock()
    private var stored: [UUID]
    private var shouldFailNextSave: Bool
    private var loadResultOverride: TemporaryPairedKeyTrackingLoad?

    init(
        initial: [UUID] = [],
        failNextSave: Bool = false,
        loadResult: TemporaryPairedKeyTrackingLoad? = nil
    ) {
        self.stored = initial
        self.shouldFailNextSave = failNextSave
        self.loadResultOverride = loadResult
    }

    func load() -> TemporaryPairedKeyTrackingLoad {
        lock.withLock {
            if let loadResultOverride {
                return loadResultOverride
            }
            return .loaded(stored)
        }
    }

    func save(_ ids: [UUID]) -> Bool {
        lock.withLock {
            if shouldFailNextSave {
                shouldFailNextSave = false
                return false
            }
            stored = ids
            return true
        }
    }

    func snapshot() -> [UUID] {
        lock.withLock { stored }
    }

    func setFailNextSave(_ value: Bool) {
        lock.withLock { shouldFailNextSave = value }
    }
}

private final class RecordingTemporaryPairedKeyDeleter:
    TemporaryPairedKeyDeleting, @unchecked Sendable
{
    private let lock = NSLock()
    private var recordedIds: [UUID] = []
    private var failingIds: Set<UUID>
    private var failAll: Bool
    private var revocationPersistenceReady: Bool
    private let onDelete: (@Sendable (UUID) -> Void)?

    init(
        failingIds: Set<UUID> = [],
        failAll: Bool = false,
        revocationPersistenceReady: Bool = true,
        onDelete: (@Sendable (UUID) -> Void)? = nil
    ) {
        self.failingIds = failingIds
        self.failAll = failAll
        self.revocationPersistenceReady = revocationPersistenceReady
        self.onDelete = onDelete
    }

    var deletedIds: [UUID] {
        lock.withLock { recordedIds }
    }

    func setFailingIds(_ ids: Set<UUID>) {
        lock.withLock { failingIds = ids }
    }

    func setFailAll(_ value: Bool) {
        lock.withLock { failAll = value }
    }

    func deleteTemporaryKey(id: UUID) -> Bool {
        let shouldFail = lock.withLock {
            recordedIds.append(id)
            return failAll || failingIds.contains(id)
        }
        guard !shouldFail else { return false }
        onDelete?(id)
        return true
    }

    func isRevocationPersistenceReady() -> Bool {
        lock.withLock { revocationPersistenceReady }
    }
}

private final class BlockingTemporaryPairedKeyPersistence:
    TemporaryPairedKeyPersisting, @unchecked Sendable
{
    let saveStarted = DispatchSemaphore(value: 0)
    let releaseSave = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var stored: [UUID] = []

    func load() -> TemporaryPairedKeyTrackingLoad { .loaded([]) }

    func save(_ ids: [UUID]) -> Bool {
        saveStarted.signal()
        _ = releaseSave.wait(timeout: .now() + 2)
        lock.withLock { stored = ids }
        return true
    }

    func snapshot() -> [UUID] {
        lock.withLock { stored }
    }
}

/// Thread-safe key set so `@Sendable` delete hooks can mutate safely.
private final class KeySet: @unchecked Sendable {
    private let lock = NSLock()
    private var values: Set<UUID>

    init(_ values: Set<UUID>) {
        self.values = values
    }

    func remove(_ id: UUID) {
        lock.lock()
        values.remove(id)
        lock.unlock()
    }

    func contains(_ id: UUID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return values.contains(id)
    }

    func snapshot() -> Set<UUID> {
        lock.lock()
        defer { lock.unlock() }
        return values
    }
}

private final class LockedValue<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) {
        self.value = value
    }

    func set(_ newValue: Value) {
        lock.withLock { value = newValue }
    }

    func mutate(_ body: (inout Value) -> Void) {
        lock.withLock { body(&value) }
    }

    func snapshot() -> Value {
        lock.withLock { value }
    }
}

@Suite("TemporaryPairedKeyStore crash-safe reconciliation")
struct TemporaryPairedKeyStoreTests {

    // MARK: - Durable registration

    @Test("registration durably records an ID that survives a new store instance")
    func registrationPersistsAcrossRelaunchSimulation() {
        let persistence = InMemoryTemporaryPairedKeyPersistence()
        let store = TemporaryPairedKeyStore(
            persistence: persistence,
            keyDeleter: RecordingTemporaryPairedKeyDeleter(),
            reconcileOnInit: false
        )
        let id = UUID()

        #expect(store.register(keyId: id))
        #expect(store.isTemporary(id: id))
        #expect(persistence.snapshot() == [id])

        // Simulate process relaunch with the same durable backend but without
        // auto-reconcile so we can assert the tracking record itself survived.
        let relaunched = TemporaryPairedKeyStore(
            persistence: persistence,
            keyDeleter: RecordingTemporaryPairedKeyDeleter(),
            reconcileOnInit: false
        )
        #expect(relaunched.isTemporary(id: id))
        #expect(relaunched.trackedKeyIds() == [id])
    }

    // MARK: - Graceful shutdown cleanup

    @Test("shutdown cleanup deletes the API key and clears tracking on success")
    func shutdownCleanupDeletesKeyAndTracking() {
        let tempId = UUID()
        let permanentId = UUID()
        let remainingKeys = KeySet([tempId, permanentId])
        let persistence = InMemoryTemporaryPairedKeyPersistence()
        let deleter = RecordingTemporaryPairedKeyDeleter { id in
            remainingKeys.remove(id)
        }
        let store = TemporaryPairedKeyStore(
            persistence: persistence,
            keyDeleter: deleter,
            reconcileOnInit: false
        )

        #expect(store.register(keyId: tempId))
        #expect(store.finishMint(keyId: tempId))
        store.beginShutdown()
        store.cleanupTrackedKeysOnShutdown()

        #expect(deleter.deletedIds == [tempId])
        #expect(!remainingKeys.contains(tempId))
        #expect(remainingKeys.contains(permanentId), "permanent keys must never be deleted")
        #expect(store.trackedKeyIds().isEmpty)
        #expect(persistence.snapshot().isEmpty)
        #expect(!store.isTemporary(id: tempId))
    }

    // MARK: - Crash orphan reconciliation

    @Test("a newly initialized store reconciles crash-orphaned temporary keys")
    func relaunchReconcilesCrashOrphans() {
        let orphanId = UUID()
        let permanentId = UUID()
        let remainingKeys = KeySet([orphanId, permanentId])
        let persistence = InMemoryTemporaryPairedKeyPersistence(initial: [orphanId])
        let deleter = RecordingTemporaryPairedKeyDeleter { id in
            remainingKeys.remove(id)
        }

        let store = TemporaryPairedKeyStore(
            persistence: persistence,
            keyDeleter: deleter,
            reconcileOnInit: true
        )

        #expect(deleter.deletedIds == [orphanId])
        #expect(!remainingKeys.contains(orphanId))
        #expect(remainingKeys.contains(permanentId))
        #expect(store.trackedKeyIds().isEmpty)
        #expect(persistence.snapshot().isEmpty)
        #expect(!store.isTemporary(id: orphanId))
    }

    // MARK: - Durable revocation / metadata failure retains tracking

    @Test("durable revocation failure retains tracking and does not clear the id")
    func durableRevocationFailureRetainsTracking() {
        let id = UUID()
        let persistence = InMemoryTemporaryPairedKeyPersistence(initial: [id])
        let deleter = RecordingTemporaryPairedKeyDeleter(failAll: true)
        let store = TemporaryPairedKeyStore(
            persistence: persistence,
            keyDeleter: deleter,
            reconcileOnInit: false
        )

        let outcome = store.ensureLaunchReconciliation()
        #expect(outcome != .ready)
        if case .failed(let reason) = outcome {
            #expect(reason.contains("durably revoke"))
        } else {
            Issue.record("expected failed outcome")
        }
        #expect(deleter.deletedIds == [id])
        #expect(store.trackedKeyIds() == [id])
        #expect(persistence.snapshot() == [id])
    }

    @Test("API metadata / delete failure retains tracking (same checked seam)")
    func apiMetadataFailureRetainsTracking() {
        // The production deleter maps API metadata load failure and revocation
        // failure onto deleteTemporaryKey -> false. This seam proves the store
        // never clears tracking when the checked delete reports failure.
        let id = UUID()
        let persistence = InMemoryTemporaryPairedKeyPersistence()
        let deleter = RecordingTemporaryPairedKeyDeleter(failingIds: [id])
        let store = TemporaryPairedKeyStore(
            persistence: persistence,
            keyDeleter: deleter,
            reconcileOnInit: false
        )
        #expect(store.register(keyId: id))
        #expect(store.finishMint(keyId: id))

        store.cleanupTrackedKeysOnShutdown()

        #expect(deleter.deletedIds == [id])
        #expect(store.trackedKeyIds() == [id])
        #expect(persistence.snapshot() == [id])
        #expect(store.isTemporary(id: id))
    }

    // MARK: - Unavailable / corrupt tracking blocks reconciliation

    @Test("unavailable or corrupt tracking blocks reconciliation and erases nothing")
    func unavailableTrackingBlocksReconciliation() {
        let persistence = InMemoryTemporaryPairedKeyPersistence(
            loadResult: .unavailableOrCorrupt
        )
        let deleter = RecordingTemporaryPairedKeyDeleter()
        let store = TemporaryPairedKeyStore(
            persistence: persistence,
            keyDeleter: deleter,
            reconcileOnInit: false
        )

        #expect(!store.isTrackingAvailable())
        let outcome = store.ensureLaunchReconciliation()
        #expect(outcome != .ready)
        if case .failed(let reason) = outcome {
            #expect(reason.contains("unavailable or corrupt"))
        } else {
            Issue.record("expected failed outcome")
        }
        #expect(deleter.deletedIds.isEmpty)
        #expect(store.trackedKeyIds().isEmpty)
        // Must not have written an empty recovery record over unknown state.
        #expect(persistence.snapshot().isEmpty)
        #expect(!store.register(keyId: UUID()))
    }

    @Test("unavailable revocation persistence blocks even with empty tracking")
    func unavailableRevocationPersistenceBlocksEmptyReconciliation() {
        let persistence = InMemoryTemporaryPairedKeyPersistence()
        let deleter = RecordingTemporaryPairedKeyDeleter(
            revocationPersistenceReady: false
        )
        let store = TemporaryPairedKeyStore(
            persistence: persistence,
            keyDeleter: deleter,
            reconcileOnInit: false
        )

        let outcome = store.ensureLaunchReconciliation()
        #expect(outcome != .ready)
        if case .failed(let reason) = outcome {
            #expect(reason.contains("revocation persistence"))
        } else {
            Issue.record("expected failed outcome")
        }
        #expect(deleter.deletedIds.isEmpty)
        #expect(persistence.snapshot().isEmpty)
    }

    @Test("corrupt tracking payloads decode as nil (fail closed)")
    func corruptPayloadsAreRejected() throws {
        let corrupt = Data("not-json".utf8)
        #expect(KeychainTemporaryPairedKeyPersistence.decode(corrupt) == nil)

        let partialCorrupt = try JSONEncoder().encode(["ids": ["not-a-uuid", UUID().uuidString]])
        #expect(KeychainTemporaryPairedKeyPersistence.decode(partialCorrupt) == nil)

        #expect(KeychainTemporaryPairedKeyPersistence.decode(Data("{\"ids\":[]}".utf8)) == [])
        let goodId = UUID()
        let good = try JSONEncoder().encode(["ids": [goodId.uuidString]])
        #expect(KeychainTemporaryPairedKeyPersistence.decode(good) == [goodId])
    }

    @Test("revocation recovery preserves pending revokes and maximum thresholds")
    func revocationRecoveryIsMonotonic() {
        let merged = RevocationStore.mergeForRecovery(
            currentRevokedKeys: ["pending"],
            currentThresholds: ["agent-a": 8, "agent-b": 2],
            loadedRevokedKeys: ["durable"],
            loadedThresholds: ["agent-a": 3, "agent-b": 9, "agent-c": 4]
        )
        #expect(merged.revokedKeys == ["pending", "durable"])
        #expect(
            merged.counterThresholds
                == ["agent-a": 8, "agent-b": 9, "agent-c": 4]
        )
    }

    // MARK: - Shutdown rejects new registrations

    @Test("shutdown rejects new temporary registrations")
    func shutdownRejectsNewRegistrations() {
        let persistence = InMemoryTemporaryPairedKeyPersistence()
        let store = TemporaryPairedKeyStore(
            persistence: persistence,
            keyDeleter: RecordingTemporaryPairedKeyDeleter(),
            reconcileOnInit: false
        )
        let before = UUID()
        #expect(store.register(keyId: before))

        store.beginShutdown()

        let after = UUID()
        #expect(!store.register(keyId: after))
        #expect(store.trackedKeyIds() == [before])
        #expect(!store.isTemporary(id: after))
        #expect(persistence.snapshot() == [before])
    }

    @Test("shutdown latch does not wait behind blocked persistence")
    func shutdownLatchDoesNotBlockMainThread() {
        let persistence = BlockingTemporaryPairedKeyPersistence()
        let store = TemporaryPairedKeyStore(
            persistence: persistence,
            keyDeleter: RecordingTemporaryPairedKeyDeleter(),
            reconcileOnInit: false
        )
        let id = UUID()
        let registrationFinished = DispatchSemaphore(value: 0)
        let shutdownFinished = DispatchSemaphore(value: 0)
        let registrationResult = LockedValue<Bool?>(nil)

        DispatchQueue.global().async {
            let result = store.register(keyId: id)
            registrationResult.set(result)
            registrationFinished.signal()
        }
        #expect(persistence.saveStarted.wait(timeout: .now() + 1) == .success)

        DispatchQueue.global().async {
            store.beginShutdown()
            shutdownFinished.signal()
        }
        #expect(
            shutdownFinished.wait(timeout: .now() + 0.25) == .success,
            "beginShutdown must not wait for Keychain persistence"
        )

        persistence.releaseSave.signal()
        #expect(registrationFinished.wait(timeout: .now() + 1) == .success)
        #expect(registrationResult.snapshot() == false)
        // The durable pointer remains recoverable even though minting was
        // refused after shutdown won the race.
        #expect(persistence.snapshot() == [id])
    }

    @Test("shutdown retains a registered key while its mint is in flight")
    func shutdownRetainsInFlightMintTracking() {
        let id = UUID()
        let persistence = InMemoryTemporaryPairedKeyPersistence()
        let deleter = RecordingTemporaryPairedKeyDeleter()
        let store = TemporaryPairedKeyStore(
            persistence: persistence,
            keyDeleter: deleter,
            reconcileOnInit: false
        )

        #expect(store.register(keyId: id))
        store.beginShutdown()
        store.cleanupTrackedKeysOnShutdown()

        #expect(deleter.deletedIds.isEmpty)
        #expect(store.trackedKeyIds() == [id])
        #expect(persistence.snapshot() == [id])
        #expect(!store.finishMint(keyId: id))
    }

    // MARK: - Retry clears only succeeded IDs

    @Test("retry success clears only IDs whose durable delete succeeded")
    func retrySuccessClearsOnlySucceededIds() {
        let okId = UUID()
        let failId = UUID()
        let persistence = InMemoryTemporaryPairedKeyPersistence(initial: [okId, failId])
        let deleter = RecordingTemporaryPairedKeyDeleter(failingIds: [failId])
        let store = TemporaryPairedKeyStore(
            persistence: persistence,
            keyDeleter: deleter,
            reconcileOnInit: false
        )

        let first = store.ensureLaunchReconciliation()
        #expect(first != .ready)
        #expect(store.trackedKeyIds() == [failId])
        #expect(Set(persistence.snapshot()) == [failId])
        #expect(Set(deleter.deletedIds) == [okId, failId])

        // Second pass: previously-failed id now succeeds.
        deleter.setFailingIds([])
        let second = store.ensureLaunchReconciliation()
        #expect(second == .ready)
        #expect(store.trackedKeyIds().isEmpty)
        #expect(persistence.snapshot().isEmpty)
        #expect(deleter.deletedIds.filter { $0 == failId }.count == 2)
    }

    // MARK: - Idempotent missing-key cleanup

    @Test("missing-key cleanup is idempotent when checked delete succeeds")
    func missingKeyCleanupIsIdempotent() {
        let missingId = UUID()
        let persistence = InMemoryTemporaryPairedKeyPersistence(initial: [missingId])
        // Deleter returns true (API path: safe load + absent key => succeeded).
        let deleter = RecordingTemporaryPairedKeyDeleter()
        let store = TemporaryPairedKeyStore(
            persistence: persistence,
            keyDeleter: deleter,
            reconcileOnInit: true
        )
        #expect(deleter.deletedIds == [missingId])
        #expect(persistence.snapshot().isEmpty)

        #expect(store.ensureLaunchReconciliation() == .ready)
        store.cleanupTrackedKeysOnShutdown()
        #expect(deleter.deletedIds == [missingId])
        #expect(store.trackedKeyIds().isEmpty)
    }

    // MARK: - Permanent keys untouched

    @Test("permanent keys are never deleted by temporary reconciliation")
    func permanentKeysNeverDeleted() {
        let permanentA = UUID()
        let permanentB = UUID()
        let remainingKeys = KeySet([permanentA, permanentB])
        let persistence = InMemoryTemporaryPairedKeyPersistence(initial: [])
        let deleter = RecordingTemporaryPairedKeyDeleter { id in
            remainingKeys.remove(id)
        }
        let store = TemporaryPairedKeyStore(
            persistence: persistence,
            keyDeleter: deleter,
            reconcileOnInit: true
        )

        #expect(store.ensureLaunchReconciliation() == .ready)
        store.beginShutdown()
        store.cleanupTrackedKeysOnShutdown()

        #expect(deleter.deletedIds.isEmpty)
        #expect(remainingKeys.snapshot() == [permanentA, permanentB])
    }

    // MARK: - Ordering / rollback

    @Test("persistence failure refuses registration so no untracked credential is implied")
    func persistenceFailureBlocksRegistration() {
        let persistence = InMemoryTemporaryPairedKeyPersistence(failNextSave: true)
        let store = TemporaryPairedKeyStore(
            persistence: persistence,
            keyDeleter: RecordingTemporaryPairedKeyDeleter(),
            reconcileOnInit: false
        )
        let id = UUID()

        #expect(!store.register(keyId: id))
        #expect(!store.isTemporary(id: id))
        #expect(persistence.snapshot().isEmpty)
    }

    @Test("key-creation failure unregisters the durable tracking record")
    func keyCreationFailureRollsBackTracking() {
        let persistence = InMemoryTemporaryPairedKeyPersistence()
        let store = TemporaryPairedKeyStore(
            persistence: persistence,
            keyDeleter: RecordingTemporaryPairedKeyDeleter(),
            reconcileOnInit: false
        )
        let id = UUID()

        #expect(store.register(keyId: id))
        #expect(persistence.snapshot() == [id])

        store.unregister(keyId: id)

        #expect(!store.isTemporary(id: id))
        #expect(persistence.snapshot().isEmpty)
        store.unregister(keyId: id)
        #expect(persistence.snapshot().isEmpty)
    }

    @Test("track-before-create ordering: orphan tracking without a key cleans up safely")
    func trackBeforeCreateOrphanIsSafeOnRelaunch() {
        let pendingId = UUID()
        let persistence = InMemoryTemporaryPairedKeyPersistence(initial: [pendingId])
        let deleter = RecordingTemporaryPairedKeyDeleter()
        let store = TemporaryPairedKeyStore(
            persistence: persistence,
            keyDeleter: deleter,
            reconcileOnInit: true
        )

        #expect(deleter.deletedIds == [pendingId])
        #expect(store.trackedKeyIds().isEmpty)
        #expect(persistence.snapshot().isEmpty)
    }

    // MARK: - Source ordering (reconcile-before-bind / cleanup-after-server-stop)

    @Test("production wiring: track-before-mint, reconcile-before-bind, cleanup-after-stop")
    func productionWiringPreservesCrashOrdering() throws {
        let coreRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // Identity
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // OsaurusCore

        let handler = try String(
            contentsOf: coreRoot.appendingPathComponent("Networking/HTTPHandler.swift"),
            encoding: .utf8
        )
        let pairStart = try #require(handler.range(of: "private func handlePairEndpoint("))
        let pairEnd = try #require(
            handler.range(
                of: "private func handlePairInviteEndpoint(",
                range: pairStart.upperBound ..< handler.endIndex
            )
        )
        let pairBody = handler[pairStart.lowerBound ..< pairEnd.lowerBound]
        let register = try #require(pairBody.range(of: ".register(keyId: pendingId)"))
        let mint = try #require(
            pairBody.range(
                of: "keyId: keyId",
                range: register.upperBound ..< pairBody.endIndex
            )
        )
        #expect(register.lowerBound < mint.lowerBound)
        #expect(pairBody.contains(".unregister(keyId: keyId)"))
        // Permanent path must not register temporary tracking.
        #expect(pairBody.contains("if isPermanent"))
        #expect(pairBody.contains("preassignedKeyId = nil"))

        let appDelegate = try String(
            contentsOf: coreRoot.appendingPathComponent("AppDelegate.swift"),
            encoding: .utf8
        )
        let serverController = try String(
            contentsOf: coreRoot.appendingPathComponent("Networking/ServerController.swift"),
            encoding: .utf8
        )
        let osaurusServer = try String(
            contentsOf: coreRoot.appendingPathComponent("Networking/OsaurusServer.swift"),
            encoding: .utf8
        )
        let reconcile = try #require(
            serverController.range(
                of: "TemporaryPairedKeyStore.reconcileSharedBeforeServerStart()"
            )
        )
        let serverStart = try #require(serverController.range(of: "try await server.start("))
        #expect(reconcile.lowerBound < serverStart.lowerBound)
        #expect(serverController.contains("Server start refused"))
        #expect(serverController.contains("guard case .ready = reconciliation"))
        #expect(serverController.contains("guard !isRunning, !isStartInFlight"))
        #expect(serverController.contains("self.serverActor = server"))
        #expect(serverController.contains("isShutdownRequested()"))
        #expect(osaurusServer.contains("self.group = group"))
        #expect(osaurusServer.contains("lifecycleGeneration == startGeneration"))

        let ensureShutdown = try #require(
            appDelegate.range(of: "await self.serverController.ensureShutdown()")
        )
        let cleanup = try #require(
            appDelegate.range(
                of: "TemporaryPairedKeyStore.shared.cleanupTrackedKeysOnShutdownOffMain()",
                range: ensureShutdown.upperBound ..< appDelegate.endIndex
            )
        )
        #expect(ensureShutdown.lowerBound < cleanup.lowerBound)
        #expect(appDelegate.contains("TemporaryPairedKeyStore.shared.beginShutdown()"))
        // Must not rely on willTerminate observer for temporary-key cleanup.
        #expect(!appDelegate.contains("willTerminateNotification"))

        let storeSource = try String(
            contentsOf: coreRoot.appendingPathComponent("Identity/TemporaryPairedKeyStore.swift"),
            encoding: .utf8
        )
        #expect(!storeSource.contains("willTerminateNotification"))
        #expect(!storeSource.contains("NSApplication.willTerminateNotification"))

        let keyManager = try String(
            contentsOf: coreRoot.appendingPathComponent("Identity/APIKeyManager.swift"),
            encoding: .utf8
        )
        #expect(keyManager.contains("deleteTemporaryKeyChecked"))
        #expect(keyManager.contains("revokeKeySynchronously"))
        #expect(keyManager.contains("guard Self.saveToKeychain(keys) else"))
        #expect(keyManager.contains("guard didLoadFromKeychain, !metadataLoadUnavailable else"))
        #expect(keyManager.contains("throw APIKeyPersistenceError.metadataReadFailed"))
        #expect(keyManager.contains("throw APIKeyPersistenceError.metadataWriteFailed"))

        let revocation = try String(
            contentsOf: coreRoot.appendingPathComponent("Identity/RevocationStore.swift"),
            encoding: .utf8
        )
        #expect(revocation.contains("func revokeKeySynchronously"))
        #expect(revocation.contains("saveSynchronously"))
        #expect(revocation.contains("Keychain.writeAfterPendingWrites"))
        #expect(revocation.contains("guard persistenceAvailable else { return false }"))
        #expect(revocation.contains("Self.mergeForRecovery"))
        // Best-effort public path remains background; checked path is sync.
        #expect(revocation.contains("saveInBackground"))
    }

    @Test("checked Keychain writes wait behind older background snapshots")
    func keychainWriteQueuePreservesMonotonicOrder() {
        let firstStarted = DispatchSemaphore(value: 0)
        let releaseFirst = DispatchSemaphore(value: 0)
        let checkedFinished = DispatchSemaphore(value: 0)
        let order = LockedValue<[String]>([])

        Keychain.performOrderedWrite(waitUntilFinished: false) {
            firstStarted.signal()
            _ = releaseFirst.wait(timeout: .now() + 2)
            order.mutate { $0.append("older-background") }
            return true
        }
        #expect(firstStarted.wait(timeout: .now() + 1) == .success)

        DispatchQueue.global().async {
            _ = Keychain.performOrderedWrite(waitUntilFinished: true) {
                order.mutate { $0.append("checked") }
                return true
            }
            checkedFinished.signal()
        }
        #expect(
            checkedFinished.wait(timeout: .now() + 0.1) == .timedOut,
            "checked write must wait for the earlier snapshot"
        )
        releaseFirst.signal()
        #expect(checkedFinished.wait(timeout: .now() + 1) == .success)
        #expect(order.snapshot() == ["older-background", "checked"])
    }

    // MARK: - Concurrency

    @Test("concurrent and duplicate registration does not corrupt tracking")
    func concurrentAndDuplicateRegistrationIsSafe() async {
        let persistence = InMemoryTemporaryPairedKeyPersistence()
        let store = TemporaryPairedKeyStore(
            persistence: persistence,
            keyDeleter: RecordingTemporaryPairedKeyDeleter(),
            reconcileOnInit: false
        )

        let sharedId = UUID()
        let uniqueCount = 40
        let uniqueIds = (0..<uniqueCount).map { _ in UUID() }

        await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<uniqueCount {
                group.addTask { store.register(keyId: sharedId) }
            }
            for id in uniqueIds {
                group.addTask { store.register(keyId: id) }
            }
            var successes = 0
            for await ok in group where ok {
                successes += 1
            }
            #expect(successes == uniqueCount + uniqueCount)
        }

        let tracked = store.trackedKeyIds()
        #expect(tracked.contains(sharedId))
        #expect(tracked.count == uniqueCount + 1)
        #expect(Set(persistence.snapshot()) == tracked)

        #expect(store.register(keyId: sharedId))
        #expect(store.trackedKeyIds().count == uniqueCount + 1)
    }

    // MARK: - Off-main reconciliation seam

    @Test("off-main reconciliation returns the same outcome as the sync path")
    func offMainReconciliationMatchesSyncPath() async {
        let id = UUID()
        let persistence = InMemoryTemporaryPairedKeyPersistence(initial: [id])
        let deleter = RecordingTemporaryPairedKeyDeleter()
        let store = TemporaryPairedKeyStore(
            persistence: persistence,
            keyDeleter: deleter,
            reconcileOnInit: false
        )

        let outcome = await store.ensureLaunchReconciliationOffMain()
        #expect(outcome == .ready)
        #expect(store.trackedKeyIds().isEmpty)
        #expect(deleter.deletedIds == [id])
    }

    @Test("a cached successful reconciliation is invalidated by shutdown")
    func shutdownPreventsLaterServerReadiness() {
        let store = TemporaryPairedKeyStore(
            persistence: InMemoryTemporaryPairedKeyPersistence(),
            keyDeleter: RecordingTemporaryPairedKeyDeleter(),
            reconcileOnInit: false
        )
        #expect(store.ensureLaunchReconciliation() == .ready)
        store.beginShutdown()
        #expect(store.ensureLaunchReconciliation() != .ready)
    }
}
