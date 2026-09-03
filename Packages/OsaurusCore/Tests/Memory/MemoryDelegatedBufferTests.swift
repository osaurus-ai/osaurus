//
//  MemoryDelegatedBufferTests.swift
//  osaurusTests
//
//  Pins `MemoryService.bufferDelegatedTurn`: a spawned run buffering its
//  clean digest under the target agent must NOT re-point that agent's
//  `activeConversation` — doing so would cancel the live chat's debounce and
//  force-distill the session the user is still typing in. The delegated
//  entry point inserts the pending signal (and arms the spawn conversation's
//  own debounce) without touching the session-switch tracking.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite(.serialized)
struct MemoryDelegatedBufferTests {

    /// Isolated storage root + in-memory shared MemoryDatabase, mirroring
    /// the MemoryUserPrefixTests setup so `MemoryService.shared` (which is
    /// pinned to `MemoryDatabase.shared`) writes somewhere disposable.
    private func withMemoryFixture(
        _ body: @Sendable () async throws -> Void
    ) async throws {
        try await SandboxTestLock.runWithStoragePaths {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(
                "osaurus-memory-delegated-buffer-\(UUID().uuidString)",
                isDirectory: true
            )
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let previousRoot = OsaurusPaths.overrideRoot

            OsaurusPaths.overrideRoot = root
            MemoryConfigurationStore.invalidateCache()
            MemoryDatabase.shared.close()
            try MemoryDatabase.shared.openInMemory()
            defer {
                MemoryDatabase.shared.close()
                MemoryConfigurationStore.invalidateCache()
                OsaurusPaths.overrideRoot = previousRoot
                try? FileManager.default.removeItem(at: root)
            }

            var config = MemoryConfiguration.default
            config.enabled = true
            MemoryConfigurationStore.save(config)

            try await body()
        }
    }

    @Test func delegatedTurnBuffersWithoutRepointingActiveConversation() async throws {
        try await withMemoryFixture {
            // Unique ids: MemoryService.shared is process-global, so this
            // agent's tracking entry can't collide with other suites.
            let agent = "delegated-agent-\(UUID().uuidString)"
            let liveConversation = "live-\(UUID().uuidString)"
            let spawnConversation = "spawn-\(UUID().uuidString)"

            // The agent's direct chat claims the active conversation.
            await MemoryService.shared.bufferTurn(
                userMessage: "direct chat turn",
                assistantMessage: "reply",
                agentId: agent,
                conversationId: liveConversation
            )
            #expect(
                await MemoryService.shared.activeConversationId(forAgent: agent)
                    == liveConversation
            )

            // A spawn completes mid-chat and buffers its digest.
            await MemoryService.shared.bufferDelegatedTurn(
                userMessage: "spawn input",
                assistantMessage: "spawn digest",
                agentId: agent,
                conversationId: spawnConversation
            )

            // The live chat keeps the active slot — no early flush.
            #expect(
                await MemoryService.shared.activeConversationId(forAgent: agent)
                    == liveConversation
            )
            // Both conversations' pending signals landed.
            let spawnPending = try MemoryDatabase.shared.loadPendingSignals(
                conversationId: spawnConversation
            )
            #expect(spawnPending.count == 1)
            #expect(spawnPending.first?.userMessage == "spawn input")
            #expect(spawnPending.first?.assistantMessage == "spawn digest")
            let livePending = try MemoryDatabase.shared.loadPendingSignals(
                conversationId: liveConversation
            )
            #expect(livePending.count == 1)
        }
    }

    @Test func delegatedTurnAloneNeverClaimsTheActiveSlot() async throws {
        try await withMemoryFixture {
            let agent = "delegated-only-agent-\(UUID().uuidString)"
            let spawnConversation = "spawn-\(UUID().uuidString)"

            await MemoryService.shared.bufferDelegatedTurn(
                userMessage: "spawn input",
                assistantMessage: "spawn digest",
                agentId: agent,
                conversationId: spawnConversation
            )

            // Signal buffered, but the agent has no live conversation to
            // hijack — the slot stays empty.
            #expect(
                await MemoryService.shared.activeConversationId(forAgent: agent) == nil
            )
            let spawnPending = try MemoryDatabase.shared.loadPendingSignals(
                conversationId: spawnConversation
            )
            #expect(spawnPending.count == 1)
        }
    }
}
