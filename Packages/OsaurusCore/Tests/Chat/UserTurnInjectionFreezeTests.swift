//
//  UserTurnInjectionFreezeTests.swift
//  osaurusTests
//
//  Coverage for the frozen user-turn context prefix (memory + screen
//  context). The contract under test: once a user turn has been sent with
//  an injected prefix, every later request must replay the exact same
//  bytes for that turn —
//    • `SystemPromptComposer.composeInjectedUserPrefix` renders the prefix
//      byte-identically to the legacy per-iteration injectors,
//    • `ChatSession.applyingFrozenInjectedPrefix` replays it onto a
//      rendered user message (skipping multimodal parts messages),
//    • `SystemPromptComposer.applyFrozenMemoryPrefixes` gives the
//      HTTP/plugin paths (client-owned history) the same stability via a
//      session ledger, and
//    • the prefix survives ChatTurn / ChatTurnData persistence.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("Frozen user-turn injection")
struct UserTurnInjectionFreezeTests {

    private let memory = "recent fact about the user"
    private let screen = "[Screen Context]\nDoing: In Safari\n[/Screen Context]"

    // MARK: - composeInjectedUserPrefix byte parity with the legacy injectors

    /// `prefix + original` must reproduce what `injectMemoryPrefix` +
    /// `injectScreenContextPrefix` used to produce, byte for byte — the KV
    /// cache compares raw bytes, so "almost the same" is a full re-prefill.
    @Test func composedPrefix_matchesLegacyInjectorBytes_bothBlocks() {
        var msgs = [ChatMessage(role: "user", content: "hello world")]
        SystemPromptComposer.injectMemoryPrefix(memory, into: &msgs)
        SystemPromptComposer.injectScreenContextPrefix(screen, into: &msgs)
        let legacy = msgs[0].content ?? ""

        let prefix = SystemPromptComposer.composeInjectedUserPrefix(
            memorySection: memory,
            screenContext: screen
        )
        #expect(prefix != nil)
        #expect((prefix ?? "") + "hello world" == legacy)
    }

    @Test func composedPrefix_matchesLegacyInjectorBytes_memoryOnly() {
        var msgs = [ChatMessage(role: "user", content: "question")]
        SystemPromptComposer.injectMemoryPrefix(memory, into: &msgs)
        let legacy = msgs[0].content ?? ""

        let prefix = SystemPromptComposer.composeInjectedUserPrefix(
            memorySection: memory,
            screenContext: nil
        )
        #expect((prefix ?? "") + "question" == legacy)
    }

    @Test func composedPrefix_matchesLegacyInjectorBytes_screenOnly() {
        var msgs = [ChatMessage(role: "user", content: "question")]
        SystemPromptComposer.injectScreenContextPrefix(screen, into: &msgs)
        let legacy = msgs[0].content ?? ""

        let prefix = SystemPromptComposer.composeInjectedUserPrefix(
            memorySection: nil,
            screenContext: screen
        )
        #expect((prefix ?? "") + "question" == legacy)
    }

    /// Whitespace-only inputs collapse to nil exactly like the injectors
    /// no-op, and surrounding whitespace is trimmed the same way.
    @Test func composedPrefix_trimsAndCollapsesLikeInjectors() {
        #expect(
            SystemPromptComposer.composeInjectedUserPrefix(
                memorySection: nil,
                screenContext: nil
            ) == nil
        )
        #expect(
            SystemPromptComposer.composeInjectedUserPrefix(
                memorySection: "   \n  ",
                screenContext: "  \n "
            ) == nil
        )

        var msgs = [ChatMessage(role: "user", content: "x")]
        SystemPromptComposer.injectMemoryPrefix("  \(memory)\n", into: &msgs)
        let legacy = msgs[0].content ?? ""
        let prefix = SystemPromptComposer.composeInjectedUserPrefix(
            memorySection: "  \(memory)\n",
            screenContext: nil
        )
        #expect((prefix ?? "") + "x" == legacy)
    }

    // MARK: - applyingFrozenInjectedPrefix (chat render path)

    @Test @MainActor func applyingPrefix_prependsToTextMessage() {
        let base = ChatMessage(
            role: "user",
            content: "ask",
            tool_calls: nil,
            tool_call_id: "call_abc"
        )
        let out = ChatSession.applyingFrozenInjectedPrefix("[Memory]\nm\n[/Memory]\n\n", to: base)
        #expect(out.content == "[Memory]\nm\n[/Memory]\n\nask")
        #expect(out.role == "user")
        #expect(out.tool_call_id == "call_abc")
    }

    @Test @MainActor func applyingPrefix_isNoopForNilOrEmptyPrefix() {
        let base = ChatMessage(role: "user", content: "ask")
        #expect(ChatSession.applyingFrozenInjectedPrefix(nil, to: base).content == "ask")
        #expect(ChatSession.applyingFrozenInjectedPrefix("", to: base).content == "ask")
    }

    /// Multimodal parts messages are returned untouched — parity with the
    /// injectors' `contentParts` guard, so a turn that renders as parts
    /// (images/audio/video) never gains a text prefix.
    @Test @MainActor func applyingPrefix_skipsMultimodalMessages() {
        let base = ChatMessage(role: "user", content: "caption", contentParts: [.text("caption")])
        let out = ChatSession.applyingFrozenInjectedPrefix("P\n\n", to: base)
        #expect(out.contentParts != nil)
        #expect(out.content == "caption")
    }

    // MARK: - applyFrozenMemoryPrefixes (HTTP / plugin session ledger)

    @Test func ledger_injectsFreshMemoryIntoLatestAndReturnsRecord() {
        var msgs: [ChatMessage] = [
            ChatMessage(role: "system", content: "sys"),
            ChatMessage(role: "user", content: "hello"),
        ]
        let recorded = SystemPromptComposer.applyFrozenMemoryPrefixes(
            memorySection: "fact-1",
            frozen: [:],
            into: &msgs
        )
        #expect(recorded != nil)
        #expect(msgs[1].content == "[Memory]\nfact-1\n[/Memory]\n\nhello")
        #expect(recorded?.prefix == "[Memory]\nfact-1\n[/Memory]\n\n")
        #expect(msgs[0].content == "sys")
    }

    /// The core divergence fix: request 2 resends CLEAN history, and the
    /// ledger replays request 1's injected bytes onto the matching history
    /// message while the fresh memory lands on the new latest message.
    @Test func ledger_replaysRecordedPrefixOntoHistoryAcrossRequests() {
        // Request 1.
        var request1: [ChatMessage] = [ChatMessage(role: "user", content: "hello")]
        var ledger: [String: String] = [:]
        if let rec = SystemPromptComposer.applyFrozenMemoryPrefixes(
            memorySection: "fact-1",
            frozen: ledger,
            into: &request1
        ) {
            ledger[rec.key] = rec.prefix
        }
        let request1LatestBytes = request1[0].content ?? ""

        // Request 2: client-owned clean history + a new user message.
        var request2: [ChatMessage] = [
            ChatMessage(role: "user", content: "hello"),
            ChatMessage(role: "assistant", content: "hi"),
            ChatMessage(role: "user", content: "next question"),
        ]
        if let rec = SystemPromptComposer.applyFrozenMemoryPrefixes(
            memorySection: "fact-2",
            frozen: ledger,
            into: &request2
        ) {
            ledger[rec.key] = rec.prefix
        }

        // History user message replays request 1's exact bytes.
        #expect(request2[0].content == request1LatestBytes)
        // Latest user message carries the fresh memory.
        #expect(request2[2].content == "[Memory]\nfact-2\n[/Memory]\n\nnext question")
        // Both entries recorded under distinct keys.
        #expect(ledger.count == 2)
    }

    /// A retry that resends the identical latest message replays the
    /// RECORDED prefix (byte stability) even when fresher memory exists,
    /// and records nothing new.
    @Test func ledger_identicalRetryReplaysRecordedPrefix() {
        var request1: [ChatMessage] = [ChatMessage(role: "user", content: "hello")]
        var ledger: [String: String] = [:]
        if let rec = SystemPromptComposer.applyFrozenMemoryPrefixes(
            memorySection: "fact-1",
            frozen: ledger,
            into: &request1
        ) {
            ledger[rec.key] = rec.prefix
        }

        var retry: [ChatMessage] = [ChatMessage(role: "user", content: "hello")]
        let recorded = SystemPromptComposer.applyFrozenMemoryPrefixes(
            memorySection: "fact-99",
            frozen: ledger,
            into: &retry
        )
        #expect(recorded == nil)
        #expect(retry[0].content == request1[0].content)
    }

    /// Duplicate user texts ("yes", "continue") get distinct occurrence
    /// ordinals, so the second occurrence gets its own fresh memory rather
    /// than replaying the first occurrence's prefix.
    @Test func ledger_duplicateUserTextsGetDistinctKeys() {
        var request1: [ChatMessage] = [ChatMessage(role: "user", content: "yes")]
        var ledger: [String: String] = [:]
        if let rec = SystemPromptComposer.applyFrozenMemoryPrefixes(
            memorySection: "fact-1",
            frozen: ledger,
            into: &request1
        ) {
            ledger[rec.key] = rec.prefix
        }

        var request2: [ChatMessage] = [
            ChatMessage(role: "user", content: "yes"),
            ChatMessage(role: "assistant", content: "ok"),
            ChatMessage(role: "user", content: "yes"),
        ]
        let recorded = SystemPromptComposer.applyFrozenMemoryPrefixes(
            memorySection: "fact-2",
            frozen: ledger,
            into: &request2
        )
        // First "yes" replays fact-1; second "yes" gets fact-2 under a new key.
        #expect(request2[0].content == "[Memory]\nfact-1\n[/Memory]\n\nyes")
        #expect(request2[2].content == "[Memory]\nfact-2\n[/Memory]\n\nyes")
        #expect(recorded != nil)
        #expect(recorded.map { ledger[$0.key] == nil } == true)
    }

    @Test func ledger_skipsMultimodalLatestMessage() {
        var msgs: [ChatMessage] = [
            ChatMessage(role: "user", content: "caption", contentParts: [.text("caption")])
        ]
        let recorded = SystemPromptComposer.applyFrozenMemoryPrefixes(
            memorySection: "fact",
            frozen: [:],
            into: &msgs
        )
        #expect(recorded == nil)
        #expect(msgs[0].content == "caption")
        #expect(msgs[0].contentParts != nil)
    }

    @Test func ledger_noMemoryAndNoLedgerIsNoop() {
        var msgs: [ChatMessage] = [ChatMessage(role: "user", content: "hello")]
        let recorded = SystemPromptComposer.applyFrozenMemoryPrefixes(
            memorySection: nil,
            frozen: [:],
            into: &msgs
        )
        #expect(recorded == nil)
        #expect(msgs[0].content == "hello")
    }

    // MARK: - Session store ledger round trip

    @Test func store_recordsAndReturnsPrefixes_andInvalidateClears() async {
        let sid = "freeze-test-\(UUID().uuidString)"
        let before = await SessionToolStateStore.shared.frozenUserPrefixes(sid)
        #expect(before.isEmpty)

        await SessionToolStateStore.shared.recordUserPrefix(sid, key: "abc#0", prefix: "P\n\n")
        let after = await SessionToolStateStore.shared.frozenUserPrefixes(sid)
        #expect(after["abc#0"] == "P\n\n")

        await SessionToolStateStore.shared.invalidate(sid)
        let cleared = await SessionToolStateStore.shared.frozenUserPrefixes(sid)
        #expect(cleared.isEmpty)
    }

    // MARK: - Persistence round trip

    @Test @MainActor func chatTurnData_roundTripsInjectedContextPrefix() throws {
        let turn = ChatTurn(role: .user, content: "hello")
        turn.injectedContextPrefix = "[Memory]\nfact\n[/Memory]\n\n"

        let data = ChatTurnData(from: turn)
        let encoded = try JSONEncoder().encode(data)
        let decoded = try JSONDecoder().decode(ChatTurnData.self, from: encoded)
        #expect(decoded.injectedContextPrefix == "[Memory]\nfact\n[/Memory]\n\n")

        let restored = ChatTurn(from: decoded)
        #expect(restored.injectedContextPrefix == "[Memory]\nfact\n[/Memory]\n\n")
        #expect(restored.content == "hello")
    }

    /// Legacy sessions (no `injectedContextPrefix` key) must keep decoding.
    @Test func chatTurnData_decodesLegacyJSONWithoutPrefixKey() throws {
        let legacyJSON = """
            {
                "id": "\(UUID().uuidString)",
                "role": "user",
                "content": "old message",
                "attachments": [],
                "toolResults": {},
                "thinking": ""
            }
            """
        let decoded = try JSONDecoder().decode(ChatTurnData.self, from: Data(legacyJSON.utf8))
        #expect(decoded.injectedContextPrefix == nil)
        #expect(decoded.content == "old message")
    }

    @Test @MainActor func chatTurnPersisted_roundTripsInjectedContextPrefix() throws {
        let turn = ChatTurn(role: .user, content: "hello")
        turn.injectedContextPrefix = "P\n\n"

        let persisted = turn.toPersisted()
        let encoded = try JSONEncoder().encode(persisted)
        let decoded = try JSONDecoder().decode(ChatTurn.Persisted.self, from: encoded)
        let restored = ChatTurn.fromPersisted(decoded)
        #expect(restored.injectedContextPrefix == "P\n\n")
    }
}
