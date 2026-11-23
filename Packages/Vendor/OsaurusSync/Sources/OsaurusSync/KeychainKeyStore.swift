import Foundation
import Security

/// Keeps the device key and user secret in the Keychain.
///
/// Items use `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`: they are readable after the
/// first unlock (so sync can run while the screen is locked), never included in backups and
/// never migrated to another device. A restored device therefore gets a fresh device key, as
/// the sync model requires.
public final class KeychainKeyStore: KeyStore, @unchecked Sendable {
    public let service: String
    public let accessGroup: String?
    /// macOS only. The data protection keychain needs a signed app with a keychain access
    /// group; unsigned tools and `swift test` must use the file-based keychain. iOS always uses
    /// the data protection keychain.
    public let useDataProtectionKeychain: Bool

    public init(service: String = "ai.osaurus.sync", accessGroup: String? = nil, useDataProtectionKeychain: Bool = true) {
        self.service = service
        self.accessGroup = accessGroup
        self.useDataProtectionKeychain = useDataProtectionKeychain
    }

    private func query(_ name: String) -> [String: Any] {
        var q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: name,
            kSecAttrSynchronizable as String: false,
        ]
        if let accessGroup {
            q[kSecAttrAccessGroup as String] = accessGroup
        }
        #if os(macOS)
        if useDataProtectionKeychain {
            q[kSecUseDataProtectionKeychain as String] = true
        }
        #endif
        return q
    }

    /// Returns nil only when the item doesn't exist. Other failures throw, including
    /// `errSecInteractionNotAllowed` before the first unlock after a reboot, so the core never
    /// mistakes a locked Keychain for a missing identity.
    public func load(name: String) throws -> Data? {
        var q = query(name)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &out)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = out as? Data else { throw Self.error("load", status) }
        return data
    }

    public func store(name: String, value: Data) throws {
        var add = query(name)
        add[kSecValueData as String] = value
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        var status = SecItemAdd(add as CFDictionary, nil)
        if status == errSecDuplicateItem {
            let update: [String: Any] = [
                kSecValueData as String: value,
                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            ]
            status = SecItemUpdate(query(name) as CFDictionary, update as CFDictionary)
        }
        guard status == errSecSuccess else { throw Self.error("store", status) }
    }

    public func delete(name: String) throws {
        let status = SecItemDelete(query(name) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw Self.error("delete", status) }
    }

    static func error(_ op: String, _ status: OSStatus) -> SyncError {
        let msg = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
        return .KeyStore(code: SyncErrorCode.keyStore, detail: "\(op): \(msg)")
    }
}

/// An in-memory key store for previews and tests. Secrets are lost on exit.
public final class MemoryKeyStore: KeyStore, @unchecked Sendable {
    private var items: [String: Data] = [:]
    private let lock = NSLock()

    public init() {}

    public func load(name: String) -> Data? {
        lock.withLock { items[name] }
    }

    public func store(name: String, value: Data) throws {
        lock.withLock { items[name] = value }
    }

    public func delete(name: String) throws {
        lock.withLock { _ = items.removeValue(forKey: name) }
    }
}
