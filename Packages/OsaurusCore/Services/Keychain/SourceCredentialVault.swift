//
//  SourceCredentialVault.swift
//  osaurus
//
//  Keychain storage for source connection secrets (API tokens, IMAP
//  passwords, OAuth tokens). One account per connection field,
//  `<connection-id>:<field>`, under `ai.osaurus.sources`. Never exported.
//

import Foundation
import Security

public enum SourceCredentialVault {
    public static let tokenField = "token"
    public static let passwordField = "password"
    public static let oauthTokensField = "oauth_tokens"

    private static let service = OsaurusKeychainServices.sourceCredentials
    private static let testStoreLock = NSLock()
    private nonisolated(unsafe) static var testStore: [String: String] = [:]

    static func account(connectionId: String, field: String) -> String {
        "\(connectionId.lowercased()):\(field)"
    }

    @discardableResult
    public static func save(_ value: String, connectionId: String, field: String) -> Bool {
        let account = account(connectionId: connectionId, field: field)
        if KeychainQueryHelpers.usesInMemoryKeychainStoreForTests {
            testStoreLock.withLock { testStore[account] = value }
            return true
        }
        if KeychainQueryHelpers.disablesKeychainForProcess { return false }
        guard let data = value.data(using: .utf8) else { return false }
        return Keychain.writeItem(service: service, account: account, data: data).isSuccess
    }

    public static func read(connectionId: String, field: String) -> String? {
        let account = account(connectionId: connectionId, field: field)
        if KeychainQueryHelpers.usesInMemoryKeychainStoreForTests {
            return testStoreLock.withLock { testStore[account] }
        }
        if KeychainQueryHelpers.disablesKeychainForProcess { return nil }
        return Keychain.read(service: service, account: account).flatMap { String(data: $0, encoding: .utf8) }
    }

    public static func has(connectionId: String, field: String) -> Bool {
        !(read(connectionId: connectionId, field: field) ?? "").isEmpty
    }

    @discardableResult
    public static func delete(connectionId: String, field: String) -> Bool {
        let account = account(connectionId: connectionId, field: field)
        if KeychainQueryHelpers.usesInMemoryKeychainStoreForTests {
            testStoreLock.withLock { _ = testStore.removeValue(forKey: account) }
            return true
        }
        if KeychainQueryHelpers.disablesKeychainForProcess { return false }
        return Keychain.delete(service: service, account: account)
    }

    /// Every field the connection type stores, plus OAuth tokens.
    public static func deleteAll(connectionId: String, type: SourceConnectionType) {
        var fields = [oauthTokensField]
        if case .secret(let secretFields) = type.auth { fields += secretFields }
        for field in Set(fields) { delete(connectionId: connectionId, field: field) }
    }

    static func resetForTesting() {
        testStoreLock.withLock { testStore.removeAll() }
    }
}
