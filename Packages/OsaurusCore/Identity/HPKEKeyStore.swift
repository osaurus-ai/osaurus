//
//  HPKEKeyStore.swift
//  osaurus
//
//  X25519 keypair used as the static recipient key for HPKE-encrypted
//  relay/Bonjour traffic.
//
//  The keypair is deterministically derived from the user's Master Key
//  via HMAC-SHA512 with domain separator "osaurus-hpke-v1" — same KDF
//  pattern used by `AgentKey`. Once derived, the 32-byte private key is
//  cached in a (non-biometric) Keychain item so subsequent server
//  launches load it without re-prompting.
//
//  Why deterministic and not "fresh per launch":
//  Relay-only paired clients pin the server's HPKE public key during
//  the LAN-pairing step. If the server regenerated its key on every
//  launch, those clients would silently fail to encrypt against the new
//  key after a restart. Deterministic derivation makes the public key
//  stable across launches as long as the Master Key is stable.
//
//  When `MasterKey.exists()` is false (tests, fresh installs before
//  onboarding), the store falls back to a fresh in-memory keypair so
//  HPKE primitives still function. This fallback path is by design
//  ephemeral — it gets replaced as soon as `warmUp(masterKey:)` runs.
//

import CryptoKit
import Foundation

public final class HPKEKeyStore: @unchecked Sendable {
    public static let shared = HPKEKeyStore()

    /// Wire identifier for the negotiated suite. Sent as `hpke_suite` in
    /// Bonjour TXT records and as a parameter on the `X-Osaurus-Encryption`
    /// HTTP header. A single suite is currently supported; new versions
    /// must publish a new identifier so clients can fall back cleanly.
    public static let suiteIdentifier = "x25519-sha256-chachapoly"

    /// Apple CryptoKit ciphersuite matching `suiteIdentifier`.
    public static let ciphersuite: HPKE.Ciphersuite = .init(
        kem: .Curve25519_HKDF_SHA256,
        kdf: .HKDF_SHA256,
        aead: .chaChaPoly
    )

    private static let kdfDomain = Data("osaurus-hpke-v1".utf8)
    private static let keychainService = "com.osaurus.hpke"
    private static let keychainAccount = "x25519.v1"

    private let lock = NSLock()
    private var _privateKey: Curve25519.KeyAgreement.PrivateKey?
    private var _publicKeyBytes: Data?
    private var _publicKeyEncoded: String?
    /// True when `_privateKey` came from a deterministic source (keychain
    /// or master-key derivation). False = ephemeral fallback that should
    /// be replaced as soon as `warmUp` is callable.
    private var _isDeterministic: Bool = false

    private init() {}

    /// Currently-cached private key. Loads from the keychain on first
    /// access (no biometric prompt); generates an ephemeral keypair when
    /// nothing is persisted yet. Always returns a usable key.
    public var privateKey: Curve25519.KeyAgreement.PrivateKey {
        lock.lock()
        defer { lock.unlock() }
        return privateKeyLocked()
    }

    /// 32-byte raw public key — what Bonjour publishes and what clients
    /// pass to `HPKE.Sender`. Cached so each Bonjour-advertised agent
    /// doesn't re-derive the public key from the private key.
    public var publicKeyBytes: Data {
        lock.lock()
        defer { lock.unlock() }
        if let cached = _publicKeyBytes { return cached }
        let bytes = privateKeyLocked().publicKey.rawRepresentation
        _publicKeyBytes = bytes
        return bytes
    }

    /// Base64url (no padding) encoding of `publicKeyBytes`.
    public var publicKeyEncoded: String {
        lock.lock()
        defer { lock.unlock() }
        if let cached = _publicKeyEncoded { return cached }
        let encoded = (_publicKeyBytes ?? privateKeyLocked().publicKey.rawRepresentation).base64urlEncoded
        _publicKeyEncoded = encoded
        return encoded
    }

    /// True when the cached key was derived from the master key (and
    /// therefore stable across launches). Useful for telling callers
    /// whether to trust the published key for long-term pairing.
    public var isDeterministic: Bool {
        lock.lock()
        defer { lock.unlock() }
        _ = privateKeyLocked()
        return _isDeterministic
    }

    /// Derive the deterministic key from the master key bytes and
    /// persist it. Call from a context where the master key is already
    /// in scope (e.g., right after `MasterKey.getPrivateKey(context:)`)
    /// so this runs without a separate biometric prompt.
    ///
    /// Idempotent: re-running with the same master key yields the same
    /// derived bytes.
    public func warmUp(masterKey: Data) {
        var bytes = Self.derive(from: masterKey)
        defer {
            bytes.withUnsafeMutableBytes { ptr in
                if let base = ptr.baseAddress { memset(base, 0, ptr.count) }
            }
        }
        Self.saveKeychain(bytes)

        lock.lock()
        defer { lock.unlock() }
        if let key = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: bytes) {
            _privateKey = key
            _publicKeyBytes = key.publicKey.rawRepresentation
            _publicKeyEncoded = nil
            _isDeterministic = true
        }
    }

    /// Wipe the cached key (in-memory + keychain). Next access falls
    /// back to a fresh ephemeral keypair until `warmUp` runs again. Use
    /// when the master key has changed or the user has reset identity.
    public func reset() {
        Self.deleteKeychain()
        lock.lock()
        defer { lock.unlock() }
        _privateKey = nil
        _publicKeyBytes = nil
        _publicKeyEncoded = nil
        _isDeterministic = false
    }

    // MARK: - Private helpers

    /// Returns the cached private key, lazily loading from keychain or
    /// minting an ephemeral fallback. The caller must already hold `lock`.
    private func privateKeyLocked() -> Curve25519.KeyAgreement.PrivateKey {
        if let cached = _privateKey { return cached }
        if let bytes = Self.loadKeychain(),
           let key = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: bytes)
        {
            _privateKey = key
            _isDeterministic = true
            return key
        }
        let ephemeral = Curve25519.KeyAgreement.PrivateKey()
        _privateKey = ephemeral
        _isDeterministic = false
        return ephemeral
    }

    private static func derive(from masterKey: Data) -> Data {
        let mac = HMAC<SHA512>.authenticationCode(
            for: kdfDomain,
            using: SymmetricKey(data: masterKey)
        )
        return Data(mac.prefix(32))
    }

    private static func loadKeychain() -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data, data.count == 32 else {
            return nil
        }
        return data
    }

    private static func saveKeychain(_ bytes: Data) {
        // Idempotent: delete then add. Deletion is silent on missing.
        deleteKeychain()
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecValueData as String: bytes,
            kSecAttrLabel as String: "Osaurus HPKE Recipient Key",
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        SecItemAdd(query as CFDictionary, nil)
    }

    @discardableResult
    private static func deleteKeychain() -> OSStatus {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
        ]
        return SecItemDelete(query as CFDictionary)
    }
}
