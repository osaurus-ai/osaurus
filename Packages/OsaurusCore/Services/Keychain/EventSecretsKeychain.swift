//
//  EventSecretsKeychain.swift
//  osaurus
//
//  Keychain storage for webhook event secrets: the shared secret a caller
//  sends in a header, or the key it signs the body with (HMAC-SHA256).
//  One account per event, `webhook:<event-uuid>`. Never exported.
//

import Foundation
import Security

public enum EventSecretsKeychain {
    private static let service = OsaurusKeychainServices.eventSecrets
    private static let testStoreLock = NSLock()
    private nonisolated(unsafe) static var testStore: [String: String] = [:]

    static func account(eventID: UUID) -> String {
        "webhook:\(eventID.uuidString.lowercased())"
    }

    /// A fresh 32-byte secret, hex encoded (what most webhook senders
    /// accept as a signing key).
    public static func makeSecret() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        if SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) != errSecSuccess {
            bytes = (0..<32).map { _ in UInt8.random(in: 0...255) }
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    @discardableResult
    public static func saveSecret(_ value: String, eventID: UUID) -> Bool {
        let account = account(eventID: eventID)
        if KeychainQueryHelpers.usesInMemoryKeychainStoreForTests {
            testStoreLock.withLock { testStore[account] = value }
            return true
        }
        if KeychainQueryHelpers.disablesKeychainForProcess { return false }
        guard let data = value.data(using: .utf8) else { return false }
        return Keychain.writeItem(service: service, account: account, data: data).isSuccess
    }

    public static func secret(eventID: UUID) -> String? {
        let account = account(eventID: eventID)
        if KeychainQueryHelpers.usesInMemoryKeychainStoreForTests {
            return testStoreLock.withLock { testStore[account] }
        }
        if KeychainQueryHelpers.disablesKeychainForProcess { return nil }
        return Keychain.read(service: service, account: account).flatMap { String(data: $0, encoding: .utf8) }
    }

    public static func hasSecret(eventID: UUID) -> Bool {
        !(secret(eventID: eventID) ?? "").isEmpty
    }

    @discardableResult
    public static func deleteSecret(eventID: UUID) -> Bool {
        let account = account(eventID: eventID)
        if KeychainQueryHelpers.usesInMemoryKeychainStoreForTests {
            testStoreLock.withLock { _ = testStore.removeValue(forKey: account) }
            return true
        }
        return Keychain.delete(service: service, account: account)
    }

    static func resetForTesting() {
        testStoreLock.withLock { testStore.removeAll() }
    }
}
