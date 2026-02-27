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
import Security

public final class APIKeyManager: @unchecked Sendable {
    public static let shared = APIKeyManager()

    private let queue = DispatchQueue(label: "com.osaurus.api-keys", attributes: .concurrent)
    private var keys: [AccessKeyInfo] = []

    private static let keychainService = "com.osaurus.access-keys"
    private static let keychainAccount = "key-metadata"

    private init() {
        keys = Self.loadFromKeychain()
    }

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
        let context = LAContext()
        context.touchIDAuthenticationAllowableReuseDuration = 300

        var masterKeyData = try MasterKey.getPrivateKey(context: context)
        defer {
            masterKeyData.withUnsafeMutableBytes { ptr in
                if let base = ptr.baseAddress { memset(base, 0, ptr.count) }
            }
        }

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
            id: UUID(),
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

        queue.sync(flags: .barrier) {
            keys.append(info)
            Self.saveToKeychain(keys)
        }

        return (fullKey, info)
    }

    // MARK: - Revoke

    /// Revoke an access key by its ID. Adds (address, nonce) to the revocation store
    /// and marks the metadata as revoked.
    public func revoke(id: UUID) {
        queue.sync(flags: .barrier) {
            guard let index = keys.firstIndex(where: { $0.id == id }) else { return }
            let key = keys[index]
            RevocationStore.shared.revokeKey(address: key.iss, nonce: key.nonce)
            keys[index] = key.withRevoked()
            Self.saveToKeychain(keys)
        }
    }

    /// Revoke all keys from a given address with counter <= current counter.
    public func revokeAll(forAddress address: OsaurusID) {
        queue.sync(flags: .barrier) {
            let currentCounter = CounterStore.shared.current
            RevocationStore.shared.revokeAllBefore(address: address, counter: currentCounter)
            keys = keys.map { key in
                guard key.iss.lowercased() == address.lowercased(), !key.revoked else { return key }
                return key.withRevoked()
            }
            Self.saveToKeychain(keys)
        }
    }

    // MARK: - List

    public func listKeys() -> [AccessKeyInfo] {
        queue.sync { keys }
    }

    // MARK: - Delete All

    public func deleteAll() {
        queue.sync(flags: .barrier) {
            keys.removeAll()
            Self.saveToKeychain(keys)
        }
    }

    // MARK: - Keychain Persistence

    private static func saveToKeychain(_ keys: [AccessKeyInfo]) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(keys) else { return }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
        ]

        let existing = SecItemCopyMatching(query as CFDictionary, nil)
        if existing == errSecSuccess {
            let update: [String: Any] = [kSecValueData as String: data]
            SecItemUpdate(query as CFDictionary, update as CFDictionary)
        } else {
            var add = query
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            SecItemAdd(add as CFDictionary, nil)
        }
    }

    private static func loadFromKeychain() -> [AccessKeyInfo] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecReturnData as String: true,
        ]

        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
            let data = result as? Data
        else {
            return []
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([AccessKeyInfo].self, from: data)) ?? []
    }

    /// Force a reload from Keychain.
    public func reload() {
        queue.sync(flags: .barrier) {
            keys = Self.loadFromKeychain()
        }
    }
}
