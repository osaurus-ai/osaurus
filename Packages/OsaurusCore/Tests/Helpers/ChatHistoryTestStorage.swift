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

            // Neutralize the "sandbox enabled by default" behavior for these
            // chat/engine/persistence tests. With the sandbox available (macOS
            // 26+), the Default agent resolves to autonomous-ON, so every
            // `ChatSession.send()` would run `prepareChatExecutionMode` ->
            // `SandboxToolRegistrar.registerTools`. Depending on the global
            // `SandboxManager.State.shared.status` left by other (serialized)
            // sandbox suites, that can enter real container provisioning
            // (NSXPCConnection), which stalls headlessly in CI and delays
            // `engine.streamChat` past these tests' timeouts. Forcing the
            // availability seam OFF (and resetting status) keeps `send()` on
            // the no-sandbox path, matching what these tests assume. Held under
            // `SandboxTestLock` above, so no concurrent sandbox suite observes
            // these values; both are restored on exit.
            let previousAvailability = SandboxManager.State.shared.availability
            let previousStatus = SandboxManager.State.shared.status
            SandboxManager.State.shared.availability = .unavailable(
                reason: "sandbox neutralized for chat-history tests"
            )
            SandboxManager.State.shared.status = .notProvisioned

            let previousRoot = OsaurusPaths.overrideRoot
            let previousChatConfig = ChatConfigurationStore.load()
            let previousDefaultAgentOverride = DefaultAgentConfigurationStore.overrideDirectory
            OsaurusPaths.overrideRoot = root
            var isolatedChatConfig = previousChatConfig
            isolatedChatConfig.disableTools = true
            ChatConfigurationStore.save(isolatedChatConfig)
            DefaultAgentConfigurationStore.overrideDirectory = root.appendingPathComponent("config")
            DefaultAgentConfigurationStore.resetCacheForTests()
            DefaultAgentConfigurationStore.save(
                DefaultAgentConfiguration(
                    disableTools: true,
                    autonomousExec: nil,
                    toolSelectionMode: .manual,
                    manualToolNames: [],
                    manualSkillNames: []
                )
            )
            StorageKeyManager.shared._setKeyForTesting(
                SymmetricKey(data: Data(repeating: 0x44, count: 32))
            )
            AgentManager.shared.refresh()
            ChatSessionStore._resetForTesting()
            defer {
                ChatSessionStore._resetForTesting()
                StorageKeyManager.shared.wipeCache()
                ChatConfigurationStore.save(previousChatConfig)
                OsaurusPaths.overrideRoot = previousRoot
                DefaultAgentConfigurationStore.overrideDirectory = previousDefaultAgentOverride
                DefaultAgentConfigurationStore.resetCacheForTests()
                AgentManager.shared.refresh()
                SandboxManager.State.shared.availability = previousAvailability
                SandboxManager.State.shared.status = previousStatus
                try? FileManager.default.removeItem(at: root)
            }

            return try await body()
        }
    }
}
