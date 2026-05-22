//
//  MemoryUserPrefixTests.swift
//  osaurusTests
//
//  Verifies SystemPromptComposer.injectMemoryPrefix: memory now lives on the
//  latest user message instead of the system prompt so the system prefix
//  stays byte-stable across turns and the MLX paged KV cache can reuse the
//  conversation prefix.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite(.serialized)
struct MemoryUserPrefixTests {

    @Test
    func injectMemoryPrefix_prependsToLatestUserMessage() {
        var msgs: [ChatMessage] = [
            ChatMessage(role: "system", content: "system content"),
            ChatMessage(role: "user", content: "first"),
            ChatMessage(role: "assistant", content: "ok"),
            ChatMessage(role: "user", content: "second"),
        ]
        SystemPromptComposer.injectMemoryPrefix("recent fact", into: &msgs)

        // System message untouched.
        #expect(msgs[0].content == "system content")
        // First user message untouched.
        #expect(msgs[1].content == "first")
        // Latest user message gains the [Memory] prefix.
        let latest = msgs[3].content ?? ""
        #expect(latest.hasPrefix("[Memory]\nrecent fact\n[/Memory]\n\n"))
        #expect(latest.contains("second"))
    }

    @Test
    func injectMemoryPrefix_isNoopForNilOrBlankMemory() {
        let original: [ChatMessage] = [
            ChatMessage(role: "user", content: "hi")
        ]
        var copy = original
        SystemPromptComposer.injectMemoryPrefix(nil, into: &copy)
        #expect(copy.first?.content == original.first?.content)

        SystemPromptComposer.injectMemoryPrefix("   \n  ", into: &copy)
        #expect(copy.first?.content == original.first?.content)
    }

    @Test
    func injectMemoryPrefix_isNoopWhenNoUserMessageExists() {
        var msgs: [ChatMessage] = [
            ChatMessage(role: "system", content: "system content")
        ]
        SystemPromptComposer.injectMemoryPrefix("memory", into: &msgs)
        #expect(msgs.count == 1)
        #expect(msgs[0].content == "system content")
    }

    @Test
    func injectMemoryPrefix_preservesToolCallIdOnLatestUserMessage() {
        var msgs: [ChatMessage] = [
            ChatMessage(
                role: "user",
                content: "ask",
                tool_calls: nil,
                tool_call_id: "call_abc"
            )
        ]
        SystemPromptComposer.injectMemoryPrefix("memory", into: &msgs)
        #expect(msgs[0].tool_call_id == "call_abc")
        #expect(msgs[0].content?.contains("memory") == true)
    }

    @Test
    func composeChatContext_passesQueryToMemoryRecallGate() async throws {
        try await SandboxTestLock.runWithStoragePaths {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(
                "osaurus-memory-query-compose-\(UUID().uuidString)",
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
            config.relevanceGateMode = .heuristic
            MemoryConfigurationStore.save(config)

            let agentId = Agent.defaultId.uuidString
            try MemoryDatabase.shared.insertTranscriptTurn(
                agentId: agentId,
                conversationId: "memory-query-forwarding",
                chunkIndex: 0,
                role: "user",
                content: "Memory live fixture exact words: ultramarine prism-441",
                tokenCount: 8
            )

            let query = "exact words ultramarine prism-441"
            let context = await SystemPromptComposer.composeChatContext(
                agentId: Agent.defaultId,
                executionMode: .none,
                query: query,
                messages: [ChatMessage(role: "user", content: query)],
                toolsDisabled: true
            )

            #expect(context.memorySection?.contains("ultramarine prism-441") == true)
        }
    }
}
