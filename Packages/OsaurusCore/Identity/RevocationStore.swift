//
//  RevocationStore.swift
//  osaurus
//
//  Persistent revocation data for access keys.
//  Individual revocation by (address, nonce), bulk by counter threshold.
//

import Foundation

public final class RevocationStore: @unchecked Sendable {
    public static let shared = RevocationStore()

    private let queue = DispatchQueue(label: "com.osaurus.revocations", attributes: .concurrent)
    private var revokedKeys: Set<String> = []
    private var counterThresholds: [String: UInt64] = [:]
    /// False when the durable blob could not be read or decoded. Checked
    /// mutations must not overwrite unknown revocation state.
    private var persistenceAvailable = true

    private static let keychainService = "com.osaurus.revocations"
    private static let keychainAccount = "revocation-data"

    private init() {
        persistenceAvailable = loadChecked()
    }

    // MARK: - Individual Revocation

    /// Revoke a specific access key identified by its signer address and nonce.
    ///
    /// Best-effort: updates in-memory state immediately and schedules a
    /// background Keychain write. Prefer `revokeKeySynchronously` when a
    /// security-critical caller must know the durable write succeeded before
    /// clearing recovery state.
    public func revokeKey(address: OsaurusID, nonce: String) {
        let key = RevocationSnapshot.revocationKey(address: address, nonce: nonce)
        queue.sync(flags: .barrier) {
            revokedKeys.insert(key)
            saveInBackground()
        }
        APIKeyValidatorEpoch.shared.bump()
    }

    /// Security-critical revocation: insert `(address, nonce)` and persist
    /// synchronously. Returns `false` when the durable write fails; in that
    /// case in-memory state is rolled back so a process that thinks the key is
    /// still live cannot clear tracking as if revocation succeeded.
    @discardableResult
    func revokeKeySynchronously(address: OsaurusID, nonce: String) -> Bool {
        let key = RevocationSnapshot.revocationKey(address: address, nonce: nonce)
        let didPersist = queue.sync(flags: .barrier) { () -> Bool in
            if !persistenceAvailable {
                persistenceAvailable = loadChecked()
            }
            guard persistenceAvailable else { return false }
            let alreadyPresent = revokedKeys.contains(key)
            revokedKeys.insert(key)
            guard saveSynchronously() else {
                persistenceAvailable = false
                if !alreadyPresent {
                    revokedKeys.remove(key)
                }
                return false
            }
            return true
        }
        if didPersist {
            APIKeyValidatorEpoch.shared.bump()
        }
        return didPersist
    }

    /// Re-establish that the durable revocation blob was read successfully.
    /// Server startup uses this even when there are no temporary IDs to clean:
    /// an unavailable/corrupt revocation set must never be treated as empty.
    func ensurePersistenceAvailableSynchronously() -> Bool {
        queue.sync(flags: .barrier) {
            if !persistenceAvailable {
                persistenceAvailable = loadChecked()
            }
            guard persistenceAvailable else { return false }
            // Always checkpoint current state through the ordered writer.
            // `loadChecked` merges rather than replaces, so revocations made
            // while Keychain was unavailable become durable before server
            // readiness is granted.
            guard saveSynchronously() else {
                persistenceAvailable = false
                return false
            }
            return true
        }
    }

    // MARK: - Bulk Revocation

    /// Revoke all access keys from `address` with counter values <= `counter`.
    public func revokeAllBefore(address: OsaurusID, counter: UInt64) {
        let normalized = address.lowercased()
        queue.sync(flags: .barrier) {
            let existing = counterThresholds[normalized] ?? 0
            counterThresholds[normalized] = max(existing, counter)
            saveInBackground()
        }
        APIKeyValidatorEpoch.shared.bump()
    }

    // MARK: - Query

    /// Check if a specific key is revoked (either individually or by counter threshold).
    public func isRevoked(address: OsaurusID, nonce: String, cnt: UInt64) -> Bool {
        queue.sync {
            let key = RevocationSnapshot.revocationKey(address: address, nonce: nonce)
            if revokedKeys.contains(key) { return true }
            if let threshold = counterThresholds[address.lowercased()], cnt <= threshold { return true }
            return false
        }
    }

    // MARK: - Snapshot

    /// Create an immutable snapshot of the current revocation state for use in the validator.
    public func snapshot() -> RevocationSnapshot {
        queue.sync {
            RevocationSnapshot(
                revokedKeys: revokedKeys,
                counterThresholds: counterThresholds
            )
        }
    }

    // MARK: - Keychain Persistence

    private struct StorageModel: Codable {
        var revokedKeys: [String]
        var counterThresholds: [String: UInt64]
    }

    // The revocation blob is read/written through the shared `Keychain` helper.
    /// Best-effort background persistence used by non-critical revoke paths.
    private func saveInBackground() {
        guard persistenceAvailable else { return }
        let model = StorageModel(
            revokedKeys: Array(revokedKeys),
            counterThresholds: counterThresholds
        )
        guard let data = try? JSONEncoder().encode(model) else { return }
        Keychain.writeInBackground(
            service: Self.keychainService, account: Self.keychainAccount, data: data)
    }

    /// Synchronous checked write for security-critical revocation. Returns
    /// `false` when encoding or Keychain persistence fails.
    @discardableResult
    private func saveSynchronously() -> Bool {
        if KeychainQueryHelpers.disablesKeychainForProcess {
            return true
        }
        let model = StorageModel(
            revokedKeys: Array(revokedKeys),
            counterThresholds: counterThresholds
        )
        guard let data = try? JSONEncoder().encode(model) else { return false }
        return Keychain.writeAfterPendingWrites(
            service: Self.keychainService, account: Self.keychainAccount, data: data)
    }

    /// Load without collapsing a missing item and an inaccessible/corrupt
    /// item. Revocations are monotonic: recovered durable state is merged
    /// into current memory rather than replacing revokes accumulated while
    /// persistence was unavailable. Caller must hold the barrier queue
    /// (except during init).
    private func loadChecked() -> Bool {
        if KeychainQueryHelpers.disablesKeychainForProcess {
            return true
        }
        switch Keychain.readResult(
            service: Self.keychainService,
            account: Self.keychainAccount
        ) {
        case .missing:
            return true
        case .unavailable:
            return false
        case .value(let data):
            guard let model = try? JSONDecoder().decode(StorageModel.self, from: data) else {
                return false
            }
            let merged = Self.mergeForRecovery(
                currentRevokedKeys: revokedKeys,
                currentThresholds: counterThresholds,
                loadedRevokedKeys: Set(model.revokedKeys),
                loadedThresholds: model.counterThresholds
            )
            revokedKeys = merged.revokedKeys
            counterThresholds = merged.counterThresholds
            return true
        }
    }

    /// Pure seam for the monotonic recovery contract.
    static func mergeForRecovery(
        currentRevokedKeys: Set<String>,
        currentThresholds: [String: UInt64],
        loadedRevokedKeys: Set<String>,
        loadedThresholds: [String: UInt64]
    ) -> (revokedKeys: Set<String>, counterThresholds: [String: UInt64]) {
        var revoked = currentRevokedKeys
        revoked.formUnion(loadedRevokedKeys)
        var thresholds = currentThresholds
        for (address, loaded) in loadedThresholds {
            thresholds[address] = max(thresholds[address] ?? 0, loaded)
        }
        return (revoked, thresholds)
    }

    /// Force reload from Keychain.
    public func reload() {
        queue.sync(flags: .barrier) {
            persistenceAvailable = loadChecked()
            if persistenceAvailable, !saveSynchronously() {
                persistenceAvailable = false
            }
        }
    }
}
