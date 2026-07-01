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

    private static let keychainService = "com.osaurus.revocations"
    private static let keychainAccount = "revocation-data"

    private init() {
        load()
    }

    // MARK: - Individual Revocation

    /// Revoke a specific access key identified by its signer address and nonce.
    public func revokeKey(address: OsaurusID, nonce: String) {
        let key = RevocationSnapshot.revocationKey(address: address, nonce: nonce)
        queue.sync(flags: .barrier) {
            revokedKeys.insert(key)
            save()
        }
        APIKeyValidatorEpoch.shared.bump()
    }

    // MARK: - Bulk Revocation

    /// Revoke all access keys from `address` with counter values <= `counter`.
    public func revokeAllBefore(address: OsaurusID, counter: UInt64) {
        let normalized = address.lowercased()
        queue.sync(flags: .barrier) {
            let existing = counterThresholds[normalized] ?? 0
            counterThresholds[normalized] = max(existing, counter)
            save()
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
    private func save() {
        let model = StorageModel(
            revokedKeys: Array(revokedKeys),
            counterThresholds: counterThresholds
        )
        guard let data = try? JSONEncoder().encode(model) else { return }
        Keychain.writeInBackground(
            service: Self.keychainService, account: Self.keychainAccount, data: data)
    }

    private func load() {
        guard let data = Keychain.read(service: Self.keychainService, account: Self.keychainAccount),
            let model = try? JSONDecoder().decode(StorageModel.self, from: data)
        else { return }

        revokedKeys = Set(model.revokedKeys)
        counterThresholds = model.counterThresholds
    }

    /// Force reload from Keychain.
    public func reload() {
        queue.sync(flags: .barrier) {
            load()
        }
    }
}
