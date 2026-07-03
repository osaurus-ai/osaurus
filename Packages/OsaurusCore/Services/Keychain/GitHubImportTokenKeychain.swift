//
//  GitHubImportTokenKeychain.swift
//  osaurus
//
//  Importer-scoped storage for the optional GitHub API token used only by the
//  GitHub plugin/skill import flow.
//

import Foundation

public enum GitHubImportTokenSaveResult: Sendable, Equatable {
    case saved
    case ignoredBlank
    case rejectedInvalid
    case unavailable
}

public enum GitHubImportTokenKeychain {
    static let keychainService = "ai.osaurus.github-import"
    static let keychainAccount = "github-import-token"

    private static let testStoreLock = NSLock()
    nonisolated(unsafe) private static var testToken: String?

    public static func normalizedToken(_ raw: String?) -> String? {
        let token = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !token.isEmpty else { return nil }
        guard token.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else {
            return nil
        }
        return token
    }

    @discardableResult
    public static func saveToken(_ raw: String) -> GitHubImportTokenSaveResult {
        saveToken(raw, keychainDisabled: {
            KeychainQueryHelpers.disablesKeychainForProcess
        }, useInMemoryStore: {
            KeychainQueryHelpers.usesInMemoryKeychainStoreForTests
        })
    }

    public static func getToken() -> String? {
        getToken(keychainDisabled: {
            KeychainQueryHelpers.disablesKeychainForProcess
        }, useInMemoryStore: {
            KeychainQueryHelpers.usesInMemoryKeychainStoreForTests
        })
    }

    public static func hasToken() -> Bool {
        getToken() != nil
    }

    @discardableResult
    public static func clearToken() -> Bool {
        clearToken(keychainDisabled: {
            KeychainQueryHelpers.disablesKeychainForProcess
        }, useInMemoryStore: {
            KeychainQueryHelpers.usesInMemoryKeychainStoreForTests
        })
    }

    @discardableResult
    static func saveToken(
        _ raw: String,
        keychainDisabled: @Sendable () -> Bool,
        useInMemoryStore: @Sendable () -> Bool
    ) -> GitHubImportTokenSaveResult {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .ignoredBlank }
        guard let token = normalizedToken(raw) else { return .rejectedInvalid }
        if keychainDisabled() { return .unavailable }
        if useInMemoryStore() {
            testStoreLock.withLock { testToken = token }
            return .saved
        }
        return Keychain.write(service: keychainService, account: keychainAccount, data: Data(token.utf8))
            ? .saved
            : .unavailable
    }

    static func getToken(
        keychainDisabled: @Sendable () -> Bool,
        useInMemoryStore: @Sendable () -> Bool
    ) -> String? {
        if keychainDisabled() { return nil }
        if useInMemoryStore() {
            return testStoreLock.withLock { testToken }
        }
        return Keychain.read(service: keychainService, account: keychainAccount)
            .flatMap { String(data: $0, encoding: .utf8) }
            .flatMap(normalizedToken)
    }

    @discardableResult
    static func clearToken(
        keychainDisabled: @Sendable () -> Bool,
        useInMemoryStore: @Sendable () -> Bool
    ) -> Bool {
        if keychainDisabled() { return true }
        if useInMemoryStore() {
            testStoreLock.withLock { testToken = nil }
            return true
        }
        return Keychain.delete(service: keychainService, account: keychainAccount)
    }
}
