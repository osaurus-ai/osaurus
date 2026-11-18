//
//  SessionKeychainItems.swift
//  osaurus
//
//  Keychain items of the extra sign-in sessions of a service
//  (`<id>.session.<sessionId>.oauth.tokens`). Unit tests keep them in
//  memory, so a session's tokens can be exercised without the Keychain.
//

import Foundation
import os

enum SessionKeychainItems {
    private static let memory = OSAllocatedUnfairLock(initialState: [String: Data]())

    private static var inMemory: Bool { KeychainQueryHelpers.usesInMemoryKeychainStoreForTests }

    static func account(_ owner: UUID, session: UUID, suffix: String) -> String {
        "\(owner.uuidString).session.\(session.uuidString).\(suffix)"
    }

    @discardableResult
    static func write(service: String, account: String, data: Data) -> Bool {
        if inMemory {
            memory.withLock { $0["\(service)|\(account)"] = data }
            return true
        }
        if KeychainQueryHelpers.disablesKeychainForProcess { return false }
        return Keychain.write(service: service, account: account, data: data)
    }

    static func read(service: String, account: String) -> Data? {
        if inMemory { return memory.withLock { $0["\(service)|\(account)"] } }
        if KeychainQueryHelpers.disablesKeychainForProcess { return nil }
        return Keychain.read(service: service, account: account)
    }

    @discardableResult
    static func delete(service: String, account: String) -> Bool {
        if inMemory {
            memory.withLock { _ = $0.removeValue(forKey: "\(service)|\(account)") }
            return true
        }
        if KeychainQueryHelpers.disablesKeychainForProcess { return true }
        return Keychain.delete(service: service, account: account)
    }

    static func availability(service: String, account: String, decodes: (Data) -> Bool) -> SecretAvailability {
        if inMemory {
            guard let data = read(service: service, account: account) else { return .absent }
            return decodes(data) ? .present : .corrupt
        }
        if KeychainQueryHelpers.disablesKeychainForProcess { return .absent }
        switch Keychain.readItem(service: service, account: account) {
        case .found(let data): return decodes(data) ? .present : .corrupt
        case .notFound, .disabled: return .absent
        case .unavailable, .accessDenied, .failure: return .unavailable
        }
    }
}
