//
//  TemporaryPairedKeyStore.swift
//  osaurus
//
//  Tracks API keys generated for temporary (non-permanent) Bonjour pairings.
//
//  Contract:
//  - Temporary pairing credentials are session-scoped: they must not survive
//    force-quit / crash as ordinary durable keys.
//  - Tracking records are persisted synchronously to Keychain *before* the
//    corresponding API key is minted, so a crash cannot create an untracked
//    long-lived credential.
//  - On the next launch, any still-tracked IDs are deleted via a checked path
//    that durably revokes before clearing tracking. Missing keys are OK;
//    unavailable/corrupt tracking or failed durable revocation refuses a safe
//    reconciliation result so the HTTP server does not bind.
//  - Graceful shutdown rejects new registrations, stops the NIO server first,
//    then cleans tracked keys. Failed deletes keep their IDs tracked.
//

import Foundation

// MARK: - Tracking load result

/// Keychain (or test) load of temporary-pairing tracking IDs.
/// Distinguishes a true empty store from a read that cannot establish a safe state.
enum TemporaryPairedKeyTrackingLoad: Equatable, Sendable {
    /// No durable tracking item exists — treat as empty.
    case missing
    /// Tracking payload decoded successfully (may be empty).
    case loaded([UUID])
    /// Denied, transient, or corrupt — do not erase recovery state or start
    /// the server as if reconciliation succeeded.
    case unavailableOrCorrupt
}

/// Outcome of launch reconciliation. Server bind must only proceed on `.ready`.
enum TemporaryPairedKeyReconciliationOutcome: Equatable, Sendable {
    case ready
    case failed(String)
}

// MARK: - Persistence seam

/// Durable store for temporary-pairing key identifiers only (never secrets).
/// Synchronous writes are required so registration cannot return before the
/// crash-recovery record is on disk/Keychain.
protocol TemporaryPairedKeyPersisting: Sendable {
    func load() -> TemporaryPairedKeyTrackingLoad
    /// Persist the full set of tracked IDs. Returns `false` when the durable
    /// write fails so callers can refuse to mint an untracked credential.
    func save(_ ids: [UUID]) -> Bool
}

/// Default Keychain-backed persistence. Uses the same protected store class as
/// access-key metadata / revocations (`kSecAttrAccessibleWhenUnlockedThisDeviceOnly`).
struct KeychainTemporaryPairedKeyPersistence: TemporaryPairedKeyPersisting {
    static let keychainService = "com.osaurus.temporary-paired-keys"
    static let keychainAccount = "key-ids"

    init() {}

    func load() -> TemporaryPairedKeyTrackingLoad {
        if KeychainQueryHelpers.disablesKeychainForProcess {
            // Hermetic / keychain-disabled launches: no cross-process recovery.
            return .missing
        }
        switch Keychain.readResult(
            service: Self.keychainService,
            account: Self.keychainAccount
        ) {
        case .missing:
            return .missing
        case .unavailable:
            return .unavailableOrCorrupt
        case .value(let data):
            guard let ids = Self.decode(data) else {
                return .unavailableOrCorrupt
            }
            return .loaded(ids)
        }
    }

    func save(_ ids: [UUID]) -> Bool {
        // Keychain-disabled process (live-proof / hermetic tests): keep callers
        // unblocked for in-session tracking, but do not touch the login Keychain.
        // Crash-recovery across process restarts is intentionally unavailable
        // in that mode.
        if KeychainQueryHelpers.disablesKeychainForProcess {
            return true
        }
        let encoder = JSONEncoder()
        guard let data = try? encoder.encode(StorageModel(ids: ids.map(\.uuidString))) else {
            return false
        }
        // Synchronous write: register() must not return before the durable
        // record exists, or a crash can leave an untracked API key.
        return Keychain.write(
            service: Self.keychainService,
            account: Self.keychainAccount,
            data: data
        )
    }

    /// Decode tracking metadata. Returns `nil` for corrupt payloads so the
    /// store can fail closed without treating garbage as live key IDs.
    static func decode(_ data: Data) -> [UUID]? {
        guard let model = try? JSONDecoder().decode(StorageModel.self, from: data) else {
            return nil
        }
        var ids: [UUID] = []
        ids.reserveCapacity(model.ids.count)
        for raw in model.ids {
            guard let id = UUID(uuidString: raw) else {
                // Stale/corrupt entry — drop the whole payload rather than
                // partially applying unknown identifiers.
                return nil
            }
            ids.append(id)
        }
        return ids
    }

    private struct StorageModel: Codable {
        var ids: [String]
    }
}

// MARK: - Key deletion seam

/// Deletes access-key metadata for a tracked temporary id.
/// Returns `true` only when durable revocation/deletion succeeded (or the key
/// was already absent after a safe metadata load). Callers must retain tracking
/// when this returns `false`.
protocol TemporaryPairedKeyDeleting: Sendable {
    func deleteTemporaryKey(id: UUID) -> Bool
    /// Establish that revocation persistence is readable before server bind,
    /// including the empty-tracking case.
    func isRevocationPersistenceReady() -> Bool
}

extension TemporaryPairedKeyDeleting {
    func isRevocationPersistenceReady() -> Bool { true }
}

struct APIKeyManagerTemporaryPairedKeyDeleter: TemporaryPairedKeyDeleting {
    init() {}

    func deleteTemporaryKey(id: UUID) -> Bool {
        APIKeyManager.shared.deleteTemporaryKeyChecked(id: id) == .succeeded
    }

    func isRevocationPersistenceReady() -> Bool {
        RevocationStore.shared.ensurePersistenceAvailableSynchronously()
    }
}

// MARK: - Store

public final class TemporaryPairedKeyStore: @unchecked Sendable {
    public static let shared = TemporaryPairedKeyStore(reconcileOnInit: false)

    /// Access the lazy shared store and reconcile it on a utility queue. This
    /// keeps the shared instance's initial Keychain load off `MainActor` too;
    /// calling an instance async helper from the main actor would initialize
    /// `shared` before that helper had a chance to dispatch.
    static func reconcileSharedBeforeServerStart()
        async -> TemporaryPairedKeyReconciliationOutcome
    {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: shared.ensureLaunchReconciliation())
            }
        }
    }

    private let queue = DispatchQueue(label: "com.osaurus.temporary-paired-keys")
    private let persistence: any TemporaryPairedKeyPersisting
    private let keyDeleter: any TemporaryPairedKeyDeleting
    /// In-memory mirror of durable tracking. Mutations always persist first
    /// (for register) or only clear IDs after durable deletion succeeds.
    private var keyIds: Set<UUID> = []
    /// IDs registered by an in-flight pairing request whose mint has not yet
    /// completed. Shutdown cleanup must retain these IDs rather than treating
    /// their not-yet-created metadata as an idempotent missing key.
    private var activeMintIds: Set<UUID> = []
    /// False when the durable tracking load was denied/corrupt — reconciliation
    /// cannot establish a safe state and must not erase recovery records.
    private var trackingAvailable: Bool = true
    /// Immediate shutdown latch. It is deliberately separate from `queue`:
    /// Cmd-Q must not park the main actor behind a slow Keychain write.
    private let shutdownRequested = AtomicBool(false)
    /// Cached successful launch reconciliation only. Failures remain retriable.
    private var didSuccessfullyReconcile = false

    init(
        persistence: (any TemporaryPairedKeyPersisting)? = nil,
        keyDeleter: (any TemporaryPairedKeyDeleting)? = nil,
        reconcileOnInit: Bool = true
    ) {
        self.persistence = persistence ?? KeychainTemporaryPairedKeyPersistence()
        self.keyDeleter = keyDeleter ?? APIKeyManagerTemporaryPairedKeyDeleter()

        // Load durable IDs before optional launch reconciliation so a crash
        // recovery path can delete the associated API keys before the server
        // accepts traffic that would treat them as ordinary durable keys.
        switch self.persistence.load() {
        case .missing:
            self.keyIds = []
            self.trackingAvailable = true
        case .loaded(let ids):
            self.keyIds = Set(ids)
            self.trackingAvailable = true
        case .unavailableOrCorrupt:
            self.keyIds = []
            self.trackingAvailable = false
        }

        if reconcileOnInit {
            _ = ensureLaunchReconciliation()
        }
    }

    // MARK: - Registration (crash-consistent ordering)

    /// Durably record that `keyId` is a session-temporary pairing credential.
    ///
    /// Callers that mint temporary keys MUST:
    /// 1. Allocate a `UUID`
    /// 2. Call `register` and refuse minting if this returns `false`
    /// 3. Pass that same id into `APIKeyManager.generate(..., keyId:)`
    /// 4. Call `unregister` if key creation fails after a successful register
    ///
    /// Ordering is intentional: a crash between (2) and (3) leaves only an
    /// orphan tracking record, which launch reconciliation deletes as a no-op
    /// key delete. A crash after (3) leaves a tracked credential that the next
    /// launch revokes. Never mint first and register second.
    ///
    /// Returns `false` when tracking is unavailable, shutdown has begun, or the
    /// durable write fails — callers must not mint in those cases.
    @discardableResult
    public func register(keyId: UUID) -> Bool {
        guard !shutdownRequested.load() else { return false }
        return queue.sync {
            guard trackingAvailable, !shutdownRequested.load() else { return false }
            // Duplicate / concurrent register of the same id is a no-op success
            // once durable — do not corrupt the set or fail the second caller.
            if keyIds.contains(keyId) {
                return true
            }
            var next = keyIds
            next.insert(keyId)
            // Persist *before* updating in-memory state so a failed write never
            // claims tracking that is not recoverable after a crash.
            guard persistence.save(Self.sortedIds(next)) else {
                return false
            }
            keyIds = next
            // Shutdown may have begun while persistence was blocked. The
            // durable recovery pointer is retained for cleanup, but the caller
            // is refused permission to mint.
            guard !shutdownRequested.load() else {
                return false
            }
            activeMintIds.insert(keyId)
            return true
        }
    }

    /// Mark the mint attempt complete and report whether its credential may
    /// be returned to the caller. If shutdown began while biometric/signing
    /// work was in flight, the caller must delete the new key and fail the
    /// pairing response; durable tracking remains until that delete succeeds.
    func finishMint(keyId: UUID) -> Bool {
        queue.sync {
            activeMintIds.remove(keyId)
            return trackingAvailable && !shutdownRequested.load() && keyIds.contains(keyId)
        }
    }

    /// Drop a tracking record after a failed key mint, or after the key has
    /// already been deleted with a checked success. Idempotent for missing ids.
    ///
    /// Do **not** call this after a failed durable delete — retain tracking so
    /// the next launch can finish revocation.
    func unregister(keyId: UUID) {
        queue.sync {
            guard trackingAvailable, keyIds.contains(keyId) else { return }
            var next = keyIds
            next.remove(keyId)
            // Best-effort durable clear. Even if save fails, drop the in-memory
            // entry so the current session does not keep treating the id as live
            // after a mint rollback; a stale durable entry only causes an
            // idempotent delete on relaunch.
            _ = persistence.save(Self.sortedIds(next))
            keyIds = next
            activeMintIds.remove(keyId)
        }
    }

    public func isTemporary(id: UUID) -> Bool {
        queue.sync { keyIds.contains(id) }
    }

    /// Snapshot of currently tracked temporary key ids (tests / diagnostics).
    func trackedKeyIds() -> Set<UUID> {
        queue.sync { keyIds }
    }

    /// Whether durable tracking is available for this process (tests / diagnostics).
    func isTrackingAvailable() -> Bool {
        queue.sync { trackingAvailable }
    }

    /// Nonblocking lifecycle check used after suspension points in server
    /// startup so a `.ready` result cannot resume into a bind after Cmd-Q.
    func isShutdownRequested() -> Bool {
        shutdownRequested.load()
    }

    // MARK: - Launch reconciliation

    /// Delete API keys for every durable temporary-pairing id, retaining any
    /// IDs whose durable revocation/deletion failed. Safe to call repeatedly.
    /// Permanent keys are never touched because they are never registered here.
    @discardableResult
    func reconcileCrashOrphans() -> TemporaryPairedKeyReconciliationOutcome {
        ensureLaunchReconciliation()
    }

    /// Ensures launch reconciliation has run successfully once for the shared
    /// process store. Failures remain retriable. Used from app bootstrap so
    /// orphan cleanup happens before the HTTP server accepts traffic.
    @discardableResult
    func ensureLaunchReconciliation() -> TemporaryPairedKeyReconciliationOutcome {
        queue.sync {
            guard !shutdownRequested.load() else {
                return .failed("temporary pairing lifecycle is shutting down")
            }
            if didSuccessfullyReconcile {
                return .ready
            }
            guard trackingAvailable else {
                return .failed(
                    "temporary pairing tracking is unavailable or corrupt; refusing unsafe reconciliation"
                )
            }
            return cleanupTrackedKeysLocked(markSuccessfulReconcile: true)
        }
    }

    /// Run launch reconciliation off the main actor so Keychain I/O does not
    /// stall UI, while still completing before the caller binds the server.
    func ensureLaunchReconciliationOffMain() async -> TemporaryPairedKeyReconciliationOutcome {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: self.ensureLaunchReconciliation())
            }
        }
    }

    // MARK: - Graceful shutdown

    /// Reject new temporary registrations for the remainder of the process.
    /// Call when ordered app shutdown begins (before or as the server stops).
    func beginShutdown() {
        shutdownRequested.store(true)
    }

    /// After the NIO server has stopped accepting traffic, attempt durable
    /// deletion of every tracked temporary key. IDs whose deletion fails remain
    /// tracked for the next launch. Does not depend on `willTerminate` ordering.
    func cleanupTrackedKeysOnShutdown() {
        shutdownRequested.store(true)
        queue.sync {
            guard trackingAvailable else { return }
            _ = cleanupTrackedKeysLocked(markSuccessfulReconcile: false)
        }
    }

    /// Keep synchronous Keychain revocation and tracking writes out of the
    /// ordered shutdown task's main-actor executor.
    func cleanupTrackedKeysOnShutdownOffMain() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                self.cleanupTrackedKeysOnShutdown()
                continuation.resume()
            }
        }
    }

    // MARK: - Internals

    /// Shared cleanup for launch reconciliation and ordered shutdown.
    /// Caller must hold `queue`. Only removes IDs whose checked delete succeeds
    /// and whose remaining set can be persisted.
    private func cleanupTrackedKeysLocked(markSuccessfulReconcile: Bool)
        -> TemporaryPairedKeyReconciliationOutcome
    {
        guard keyDeleter.isRevocationPersistenceReady() else {
            return .failed(
                "revocation persistence is unavailable or corrupt; refusing unsafe reconciliation"
            )
        }
        let original = keyIds
        guard !original.isEmpty else {
            if markSuccessfulReconcile {
                didSuccessfullyReconcile = true
            }
            return .ready
        }

        // An in-flight request may have registered before shutdown but not
        // minted metadata yet. Keep that recovery pointer; deleting a
        // currently-missing key and clearing its ID would let the request mint
        // an untracked token after cleanup.
        var failed = activeMintIds.intersection(original)
        for id in original.subtracting(activeMintIds) {
            if !keyDeleter.deleteTemporaryKey(id: id) {
                failed.insert(id)
            }
        }

        // Persist the residual set (failed only). If that write fails, keep
        // the original in-memory tracking so no recovery ID is lost.
        if persistence.save(Self.sortedIds(failed)) {
            keyIds = failed
        } else {
            // Deletes that already succeeded are idempotent on retry.
            return .failed("could not persist temporary pairing tracking after cleanup")
        }

        if !failed.isEmpty {
            return .failed(
                "could not durably revoke \(failed.count) temporary pairing key(s); retaining tracking"
            )
        }

        if markSuccessfulReconcile {
            didSuccessfullyReconcile = true
        }
        return .ready
    }

    private static func sortedIds(_ ids: Set<UUID>) -> [UUID] {
        ids.sorted { $0.uuidString < $1.uuidString }
    }
}
