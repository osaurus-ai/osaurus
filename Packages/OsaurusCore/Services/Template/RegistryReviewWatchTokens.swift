//
//  RegistryReviewWatchTokens.swift
//  osaurus
//
//  The read-only token the store registry hands out (`POST
//  /me/review-watch`) so `RegistryReviewWatcher` can long-poll review
//  decisions without reading the master key. One per registry, in the
//  Keychain. In keychain-free mode (tests, live proof) it lives in memory
//  for the session and the next signed call gets another after a relaunch.
//

import Combine
import Foundation

@MainActor
public final class RegistryReviewWatchTokens: ObservableObject {
    public static let shared = RegistryReviewWatchTokens()

    nonisolated static let keychainService = "ai.osaurus.workflowsRegistry.reviewWatch"

    /// Registry key → token, for what this session has read or stored.
    @Published private var tokens: [String: String] = [:]
    /// Registries whose Keychain item has been read this session.
    private var loaded: Set<String> = []
    private let usesKeychain: Bool

    init(usesKeychain: Bool = true) {
        self.usesKeychain = usesKeychain
    }

    public func token(for registry: URL) -> String? {
        let key = WorkflowRegistryRecordStore.registryKey(registry)
        if usesKeychain, !loaded.contains(key) {
            loaded.insert(key)
            if let data = Keychain.read(service: Self.keychainService, account: key),
                let stored = String(data: data, encoding: .utf8), !stored.isEmpty
            {
                tokens[key] = stored
            }
        }
        return tokens[key]
    }

    public func set(_ token: String, for registry: URL) {
        let key = WorkflowRegistryRecordStore.registryKey(registry)
        loaded.insert(key)
        tokens[key] = token
        if usesKeychain {
            Keychain.writeInBackground(service: Self.keychainService, account: key, data: Data(token.utf8))
        }
    }

    public func remove(for registry: URL) {
        let key = WorkflowRegistryRecordStore.registryKey(registry)
        loaded.insert(key)
        tokens[key] = nil
        if usesKeychain {
            Keychain.performInBackground { Keychain.delete(service: Self.keychainService, account: key) }
        }
    }

    /// Fires whenever a token is stored or dropped.
    var changes: AnyPublisher<Void, Never> { $tokens.map { _ in () }.eraseToAnyPublisher() }
}
