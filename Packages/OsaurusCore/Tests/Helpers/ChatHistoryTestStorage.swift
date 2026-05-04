//
//  ChatHistoryTestStorage.swift
//  OsaurusCoreTests
//
//  Isolates tests that exercise ChatSession save/reset paths from the
//  real chat-history database and the user's Keychain-backed storage key.
//

import CryptoKit
import Foundation

@testable import OsaurusCore

enum ChatHistoryTestStorage {
    @MainActor
    static func run<T: Sendable>(
        _ body: @MainActor @Sendable () async throws -> T
    ) async throws -> T {
        try await SandboxTestLock.runWithStoragePaths {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(
                "osaurus-chat-history-tests-\(UUID().uuidString)"
            )
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

            let previousRoot = OsaurusPaths.overrideRoot
            OsaurusPaths.overrideRoot = root
            StorageKeyManager.shared._setKeyForTesting(
                SymmetricKey(data: Data(repeating: 0x44, count: 32))
            )
            AgentManager.shared.refresh()
            ChatSessionStore._resetForTesting()
            defer {
                ChatSessionStore._resetForTesting()
                StorageKeyManager.shared.wipeCache()
                OsaurusPaths.overrideRoot = previousRoot
                AgentManager.shared.refresh()
                try? FileManager.default.removeItem(at: root)
            }

            return try await body()
        }
    }
}
