//
//  APIKeyManager.swift
//  osaurus
//
//  Generates, persists, and revokes osk-v1 access keys signed by the
//  Master Key or a derived Agent Key.
//  Stores only metadata — never signatures or hashes.
//

import Foundation
import LocalAuthentication

private enum APIKeyPersistenceError: LocalizedError {
    case metadataReadFailed
    case metadataWriteFailed

    var errorDescription: String? {
        switch self {
        case .metadataReadFailed:
            "Could not safely read existing access-key metadata."
        case .metadataWriteFailed:
            "Could not persist access-key metadata."
        }
    }
}

/// Result of a security-critical temporary API-key deletion.
/// Internal only — not part of the public access-key management surface.
enum TemporaryAPIKeyDeletionResult: Equatable, Sendable {
    /// Key was absent after a successful metadata load, or was revoked and
    /// removed with durable revocation + metadata persistence.
    case succeeded
    /// Metadata could not be loaded, durable revocation failed, or metadata
    /// write failed. Callers must retain recovery tracking for this id.
    case failed
}

/// Typed access-key metadata Keychain load for security-critical paths.
private enum APIKeyMetadataLoad: Sendable {
    case missing
    case loaded([AccessKeyInfo])
    case unavailable
}

public final class APIKeyManager: @unchecked Sendable {
    public static let shared = APIKeyManager()

    private let queue = DispatchQueue(label: "com.osaurus.api-keys", attributes: .concurrent)
    private var keys: [AccessKeyInfo] = []
    private var didLoadFromKeychain = false
    /// Set when a security-critical load observed unavailable/corrupt metadata.
    /// Prevents treating "could not read" as an empty key list for deletion.
    private var metadataLoadUnavailable = false

    private static let keychainService = "com.osaurus.access-keys"
    private static let keychainAccount = "key-metadata"

    private init() {}

    // MARK: - Generate

    /// Create a new access key. Returns the full key string (shown once) and the persisted metadata.
    /// - Parameters:
    ///   - label: Human-readable label for the key.
    ///   - expiration: When the key expires.
    ///   - agentIndex: If set, sign with the derived agent key and scope to that agent.
    ///                 If nil, sign with the master key for all-agent access.
    public func generate(
        label: String,
        expiration: AccessKeyExpiration,
        agentIndex: UInt32? = nil
    ) throws -> (fullKey: String, info: AccessKeyInfo) {
        try generate(label: label, expiration: expiration, agentIndex: agentIndex, keyId: UUID())
    }

    /// Create a new access key with a caller-chosen metadata id.
    ///
    /// Temporary Bonjour pairing uses this after durably registering `keyId` in
    /// `TemporaryPairedKeyStore`, so a crash between registration and mint
    /// cannot leave an untracked long-lived credential (only an orphan id that
    /// launch reconciliation deletes as a no-op).
    func generate(
        label: String,
        expiration: AccessKeyExpiration,
        agentIndex: UInt32?,
        keyId: UUID
    ) throws -> (fullKey: String, info: AccessKeyInfo) {
        guard ensureLoadedFromKeychain() else {
            // Never overwrite an inaccessible/corrupt metadata blob with a
            // list containing only the new key. Temporary pairing depends on
            // this read succeeding before minting.
            throw APIKeyPersistenceError.metadataReadFailed
        }

        let context = LAContext()
        context.touchIDAuthenticationAllowableReuseDuration = 300

        var masterKeyData = try MasterKey.getPrivateKey(context: context)
        defer { masterKeyData.zeroOut() }

        let masterAddress = try deriveOsaurusId(from: masterKeyData)

        let signerAddress: OsaurusID
        let audienceAddress: OsaurusID
        if let idx = agentIndex {
            signerAddress = try AgentKey.deriveAddress(masterKey: masterKeyData, index: idx)
            audienceAddress = signerAddress
        } else {
            signerAddress = masterAddress
            audienceAddress = masterAddress
        }

        let nonce = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let cnt = CounterStore.shared.next()
        let now = Date()
        let iat = Int(now.timeIntervalSince1970)
        let expTimestamp: Int? = expiration.expirationDate(from: now).map { Int($0.timeIntervalSince1970) }

        let payload = AccessKeyPayload(
            aud: audienceAddress,
            cnt: cnt,
            exp: expTimestamp,
            iat: iat,
            iss: signerAddress,
            lbl: label.isEmpty ? nil : label,
            nonce: nonce
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let payloadData = try encoder.encode(payload)

        let signature: Data
        if let idx = agentIndex {
            signature = try AgentKey.sign(payload: payloadData, masterKey: masterKeyData, index: idx)
        } else {
            signature = try signAccessPayload(payloadData, privateKey: masterKeyData)
        }

        let fullKey = "osk-v1.\(payloadData.base64urlEncoded).\(signature.hexEncodedString)"

        let info = AccessKeyInfo(
            id: keyId,
            label: label,
            prefix: String(fullKey.prefix(20)),
            nonce: nonce,
            cnt: cnt,
            iss: signerAddress,
            aud: audienceAddress,
            createdAt: now,
            expiration: expiration,
            expiresAt: expiration.expirationDate(from: now)
        )

        let didPersist = queue.sync(flags: .barrier) {
            // Signing / biometric work above can suspend this mutation for
            // seconds. A reload may discover unavailable/corrupt metadata in
            // that interval; never append and overwrite that unknown blob
            // using the stale preflight state.
            guard didLoadFromKeychain, !metadataLoadUnavailable else {
                return false
            }
            keys.append(info)
            guard Self.saveToKeychain(keys) else {
                keys.removeAll { $0.id == keyId }
                return false
            }
            return true
        }
        guard didPersist else { throw APIKeyPersistenceError.metadataWriteFailed }
        // A new key (and possibly the first key) must be honored by the live
        // server without a restart.
        APIKeyValidatorEpoch.shared.bump()

        return (fullKey, info)
    }

    // MARK: - Revoke

    /// Revoke an access key by its ID. Adds (address, nonce) to the revocation store
    /// and marks the metadata as revoked.
    public func revoke(id: UUID) {
        guard ensureLoadedFromKeychain() else { return }

        queue.sync(flags: .barrier) {
            guard let index = keys.firstIndex(where: { $0.id == id }) else { return }
            let key = keys[index]
            RevocationStore.shared.revokeKey(address: key.iss, nonce: key.nonce)
            keys[index] = key.withRevoked()
            Self.saveToKeychain(keys)
        }
        APIKeyValidatorEpoch.shared.bump()
    }

    /// Revoke all keys from a given address with counter <= current counter.
    public func revokeAll(forAddress address: OsaurusID) {
        guard ensureLoadedFromKeychain() else { return }

        queue.sync(flags: .barrier) {
            let currentCounter = CounterStore.shared.current
            RevocationStore.shared.revokeAllBefore(address: address, counter: currentCounter)
            keys = keys.map { key in
                guard key.iss.lowercased() == address.lowercased(), !key.revoked else { return key }
                return key.withRevoked()
            }
            Self.saveToKeychain(keys)
        }
        APIKeyValidatorEpoch.shared.bump()
    }

    /// Revoke an access key and remove it from the key list entirely.
    /// Use this for temporary keys that should leave no trace after deletion.
    ///
    /// Best-effort: does not report durable write failures. Temporary pairing
    /// recovery must use `deleteTemporaryKeyChecked(id:)` instead.
    public func delete(id: UUID) {
        _ = deleteTemporaryKeyChecked(id: id)
    }

    /// Security-critical temporary-key deletion used by crash reconciliation.
    ///
    /// Returns `.succeeded` only when:
    /// - access-key metadata was loaded successfully, and
    /// - the key was already absent, or
    /// - durable synchronous revocation succeeded and metadata removal persisted.
    ///
    /// On `.failed`, callers must retain temporary-pairing tracking so a later
    /// retry (or next launch) can finish the job. Never clears tracking first.
    @discardableResult
    func deleteTemporaryKeyChecked(id: UUID) -> TemporaryAPIKeyDeletionResult {
        let outcome: TemporaryAPIKeyDeletionResult = queue.sync(flags: .barrier) {
            switch ensureMetadataReadyForSecurityCriticalMutationLocked() {
            case .unavailable:
                return .failed
            case .ready:
                break
            }

            guard let index = keys.firstIndex(where: { $0.id == id }) else {
                // Missing key after a safe load: track-before-mint orphan or
                // prior successful delete. Idempotent success.
                return .succeeded
            }

            let key = keys[index]
            // Durable revocation MUST succeed before we drop metadata (and
            // before TemporaryPairedKeyStore clears tracking).
            guard RevocationStore.shared.revokeKeySynchronously(
                address: key.iss, nonce: key.nonce)
            else {
                return .failed
            }

            keys.remove(at: index)
            guard Self.saveToKeychain(keys) else {
                // Keep the in-memory entry so a retry can re-attempt the
                // metadata write; revocation is already durable.
                keys.insert(key, at: min(index, keys.count))
                return .failed
            }
            return .succeeded
        }
        if outcome == .succeeded {
            APIKeyValidatorEpoch.shared.bump()
        }
        return outcome
    }

    // MARK: - List

    public func listKeys() -> [AccessKeyInfo] {
        queue.sync { keys }
    }

    /// Return all access keys whose audience matches `audience` (case-insensitive).
    /// Used by per-agent key management UI to scope listing/revoke to one agent.
    public func listKeys(forAudience audience: OsaurusID) -> [AccessKeyInfo] {
        let lower = audience.lowercased()
        return queue.sync {
            keys.filter { $0.aud.lowercased() == lower }
        }
    }

    /// Returns active access keys that look like pre-upgrade pairings:
    /// master-scoped (audience is *not* one of the supplied agent addresses)
    /// and never-expiring. Such keys grant access to every agent and only
    /// stop working when explicitly revoked.
    ///
    /// Pass the user's known agent addresses in `knownAgentAddresses` so
    /// agent-scoped keys are recognised even if the master address itself is
    /// not at hand (computing it requires biometric auth — we deliberately
    /// avoid prompting just to flag legacy keys for the migration UI).
    public func legacyMasterScopedKeys(
        knownAgentAddresses: Set<String>
    ) -> [AccessKeyInfo] {
        let lowerAgents = Set(knownAgentAddresses.map { $0.lowercased() })
        return queue.sync {
            keys.filter { Self.isLegacyMasterScopedKey($0, knownAgentAddressesLower: lowerAgents) }
        }
    }

    /// Pure predicate behind `legacyMasterScopedKeys` so tests can verify
    /// the classification logic without touching Keychain. `knownAgentAddressesLower`
    /// must already be lower-cased — the surrounding helper does this once.
    public static func isLegacyMasterScopedKey(
        _ info: AccessKeyInfo,
        knownAgentAddressesLower: Set<String>
    ) -> Bool {
        info.isActive
            && info.expiration == .never
            && !knownAgentAddressesLower.contains(info.aud.lowercased())
    }

    // MARK: - Delete All

    public func deleteAll() {
        queue.sync(flags: .barrier) {
            keys.removeAll()
            Self.saveToKeychain(keys)
        }
        APIKeyValidatorEpoch.shared.bump()
    }

    // MARK: - Keychain Persistence

    // The access-key metadata blob is read/written through the shared
    // `Keychain` helper.
    @discardableResult
    private static func saveToKeychain(_ keys: [AccessKeyInfo]) -> Bool {
        if KeychainQueryHelpers.disablesKeychainForProcess {
            return true
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(keys) else { return false }
        return Keychain.write(service: keychainService, account: keychainAccount, data: data)
    }

    private static func loadFromKeychainChecked() -> APIKeyMetadataLoad {
        if KeychainQueryHelpers.disablesKeychainForProcess {
            return .missing
        }
        switch Keychain.readResult(service: keychainService, account: keychainAccount) {
        case .missing:
            return .missing
        case .unavailable:
            return .unavailable
        case .value(let data):
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            guard let decoded = try? decoder.decode([AccessKeyInfo].self, from: data) else {
                return .unavailable
            }
            return .loaded(decoded)
        }
    }

    /// Force a reload from Keychain.
    public func reload() {
        queue.sync(flags: .barrier) {
            switch Self.loadFromKeychainChecked() {
            case .missing:
                keys = []
                didLoadFromKeychain = true
                metadataLoadUnavailable = false
            case .loaded(let loaded):
                keys = loaded
                didLoadFromKeychain = true
                metadataLoadUnavailable = false
            case .unavailable:
                // Do not pretend the store is empty when the read failed.
                keys = []
                didLoadFromKeychain = false
                metadataLoadUnavailable = true
            }
        }
    }

    @discardableResult
    private func ensureLoadedFromKeychain() -> Bool {
        queue.sync(flags: .barrier) {
            guard !didLoadFromKeychain else { return !metadataLoadUnavailable }
            switch Self.loadFromKeychainChecked() {
            case .missing:
                keys = []
                didLoadFromKeychain = true
                metadataLoadUnavailable = false
                return true
            case .loaded(let loaded):
                keys = loaded
                didLoadFromKeychain = true
                metadataLoadUnavailable = false
                return true
            case .unavailable:
                // Never let generation overwrite an inaccessible/corrupt
                // metadata blob as though it were an empty store.
                keys = []
                didLoadFromKeychain = false
                metadataLoadUnavailable = true
                return false
            }
        }
    }

    private enum SecurityCriticalMetadataAccess {
        case ready
        case unavailable
    }

    /// Must be called under `queue` barrier. Loads metadata when needed and
    /// refuses security-critical mutation when the Keychain read is unsafe.
    private func ensureMetadataReadyForSecurityCriticalMutationLocked()
        -> SecurityCriticalMetadataAccess
    {
        if didLoadFromKeychain {
            return metadataLoadUnavailable ? .unavailable : .ready
        }
        switch Self.loadFromKeychainChecked() {
        case .missing:
            keys = []
            didLoadFromKeychain = true
            metadataLoadUnavailable = false
            return .ready
        case .loaded(let loaded):
            keys = loaded
            didLoadFromKeychain = true
            metadataLoadUnavailable = false
            return .ready
        case .unavailable:
            metadataLoadUnavailable = true
            // Leave didLoadFromKeychain false so a later retry can re-read.
            return .unavailable
        }
    }
}
