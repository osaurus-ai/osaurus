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
}
