//
//  WorkflowSecretsKeychain.swift
//  osaurus
//
//  Keychain storage for workflow values that are not Keys: remembered
//  secret answers to dialog fields and shared connections. Accounts:
//   - `answer:<workflow-uuid>:<node-id>/<field-key>` for remembered secret
//     answers.
//   - `connection:<connection-uuid>:<field>` for `WorkflowConnectionStore`.
//   - `secret:<scope-uuid>:<KEY>` names a workflow's install-time secret
//     slot in bindings. Those values live in the Keys store
//     (`WorkflowCredentials`); items saved here before it are read only as
//     its legacy fallback.
//
//  Values never leave the Mac and are never shown again after entry.
//

import Foundation
import Security

public enum WorkflowSecretsKeychain {
    private static let service = OsaurusKeychainServices.workflowSecrets
    private static let testStoreLock = NSLock()
    private nonisolated(unsafe) static var testStore: [String: String] = [:]
    private nonisolated(unsafe) static var evalValues: [String: String]?

    private static let secretPrefix = "secret:"

    /// Headless evals: keeps every secret in memory, and answers an unset
    /// install-time secret from `values` by its key (`"*"` for any key), as a
    /// person entering the value they hold would. nil restores the Keychain.
    public static func useInMemoryStore(values: [String: String]?) {
        testStoreLock.withLock {
            evalValues = values
            testStore.removeAll()
        }
    }

    private static var usesMemory: Bool {
        KeychainQueryHelpers.usesInMemoryKeychainStoreForTests || testStoreLock.withLock { evalValues != nil }
    }

    private static func memoryRead(_ account: String) -> String? {
        testStoreLock.withLock {
            if let stored = testStore[account] { return stored }
            guard let values = evalValues, account.hasPrefix(secretPrefix),
                let key = account.split(separator: ":").last.map(String.init)
            else { return nil }
            return values[key] ?? values["*"]
        }
    }

    /// The account an install-time secret lives under for `scope`.
    public static func secretAccount(scope: UUID, key: String) -> String {
        "\(secretPrefix)\(scope.uuidString.lowercased()):\(key)"
    }

    /// Whether `account` is exactly `scope`'s account for `key`. A binding
    /// that names any other account (another workflow's secret, a saved
    /// answer) is not honored at run time.
    public static func isSecretAccount(_ account: String, scope: UUID, key: String) -> Bool {
        account.lowercased() == secretAccount(scope: scope, key: key).lowercased()
    }

    public static func answerAccount(workflowID: UUID, nodeID: String, fieldKey: String) -> String {
        "answer:\(workflowID.uuidString.lowercased()):\(nodeID)/\(fieldKey)"
    }

    // MARK: Connections

    /// `connection:<connection-uuid>:<field>` holds a shared connection's
    /// values (`WorkflowConnectionStore`): `value` for a pasted key or
    /// token, `access`, `refresh`, and `client_secret` for OAuth. A
    /// workflow secret bound to `connection:<uuid>` reads the connection
    /// instead of its own account.
    private static let connectionPrefix = "connection:"

    public static func connectionAccount(id: UUID, field: String) -> String {
        "\(connectionPrefix)\(id.uuidString.lowercased()):\(field)"
    }

    /// The binding that points a workflow secret at a connection.
    public static func connectionBinding(id: UUID) -> String {
        "\(connectionPrefix)\(id.uuidString.lowercased())"
    }

    public static func isConnectionAccount(_ account: String) -> Bool {
        connectionID(of: account) != nil
    }

    /// The connection a binding or account names.
    public static func connectionID(of account: String) -> UUID? {
        guard account.lowercased().hasPrefix(connectionPrefix) else { return nil }
        let rest = account.dropFirst(connectionPrefix.count)
        let idPart = rest.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
        return UUID(uuidString: idPart)
    }

    public static func deleteConnection(id: UUID) {
        for field in ["value", "access", "refresh", "client_secret"] {
            delete(account: connectionAccount(id: id, field: field))
        }
    }

    @discardableResult
    public static func save(_ value: String, account: String) -> Bool {
        if usesMemory {
            testStoreLock.withLock { testStore[account] = value }
            return true
        }
        if KeychainQueryHelpers.disablesKeychainForProcess { return false }
        guard let data = value.data(using: .utf8) else { return false }
        return Keychain.writeItem(service: service, account: account, data: data).isSuccess
    }

    public static func read(account: String) -> String? {
        if usesMemory { return memoryRead(account) }
        if KeychainQueryHelpers.disablesKeychainForProcess { return nil }
        return Keychain.read(service: service, account: account).flatMap { String(data: $0, encoding: .utf8) }
    }

    @discardableResult
    public static func delete(account: String) -> Bool {
        if usesMemory {
            testStoreLock.withLock { _ = testStore.removeValue(forKey: account) }
            return true
        }
        return Keychain.delete(service: service, account: account)
    }

    /// Presence of a value under `account`.
    public static func hasValue(account: String) -> Bool {
        !(read(account: account) ?? "").isEmpty
    }

    static func resetForTesting() {
        testStoreLock.withLock {
            testStore.removeAll()
            evalValues = nil
        }
    }
}
