//
//  ConversationReuseTelemetryTests.swift
//  osaurusTests
//
//  Coverage for the conversation-level KV-reuse telemetry in
//  `SessionToolStateStore`: the per-send diff that reports how many
//  history tokens the paged KV cache can reuse (contiguous matching
//  message prefix vs the previous send) and how many re-prefill. This is
//  the observable counterpart of the frozen-turn-prefix fix — a cross-turn
//  byte divergence shows up here as a truncated reuse run.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("Conversation reuse telemetry")
struct ConversationReuseTelemetryTests {

    private func fingerprint(_ messages: [ChatMessage]) -> SessionToolStateStore.ConversationFingerprint {
        SessionToolStateStore.ConversationFingerprint(messages: messages)
    }

    // MARK: - messageIdentityHash

    @Test func identityHash_isStableForEqualMessages() {
        let a = ChatMessage(role: "user", content: "hello")
        let b = ChatMessage(role: "user", content: "hello")
        #expect(
            SessionToolStateStore.messageIdentityHash(a)
                == SessionToolStateStore.messageIdentityHash(b)
        )
    }

    @Test func identityHash_distinguishesRoleContentAndToolLinkage() {
        let base = ChatMessage(role: "user", content: "hello")
        let differentRole = ChatMessage(role: "assistant", content: "hello")
        let differentContent = ChatMessage(role: "user", content: "hello!")
        let toolLinked = ChatMessage(
            role: "tool",
            content: "hello",
            tool_calls: nil,
            tool_call_id: "call_1"
        )
        let hashes = [base, differentRole, differentContent, toolLinked]
            .map(SessionToolStateStore.messageIdentityHash)
        #expect(Set(hashes).count == hashes.count)
    }

    /// Field boundaries must be separated: ("ab","c") vs ("a","bc") style
    /// concatenation collisions would fake a match across role/content.
    @Test func identityHash_doesNotCollideAcrossFieldBoundaries() {
        let a = ChatMessage(role: "user", content: "xy")
        let b = ChatMessage(role: "userx", content: "y")
        #expect(
            SessionToolStateStore.messageIdentityHash(a)
                != SessionToolStateStore.messageIdentityHash(b)
        )
    }

    @Test func identityHash_coversToolCallPayloads() {
        let call1 = ChatMessage(
            role: "assistant",
            content: nil,
            tool_calls: [
                ToolCall(
                    id: "c1",
                    type: "function",
                    function: ToolCallFunction(name: "search", arguments: "{\"q\":\"a\"}")
                )
            ],
            tool_call_id: nil
        )
        let call2 = ChatMessage(
            role: "assistant",
            content: nil,
            tool_calls: [
                ToolCall(
                    id: "c1",
                    type: "function",
                    function: ToolCallFunction(name: "search", arguments: "{\"q\":\"b\"}")
                )
            ],
            tool_call_id: nil
        )
        #expect(
            SessionToolStateStore.messageIdentityHash(call1)
                != SessionToolStateStore.messageIdentityHash(call2)
        )
    }

    // MARK: - conversationReuse

    /// First send of a session: everything is prefill (cold cache).
    @Test func reuse_firstSendCountsEverythingAsPrefill() {
        let current = fingerprint([
            ChatMessage(role: "user", content: "hello there"),
            ChatMessage(role: "assistant", content: "hi!"),
        ])
        let result = SessionToolStateStore.conversationReuse(
            previous: nil,
            current: current,
            staticPrefixMatched: true
        )
        #expect(result.reusedTokens == 0)
        #expect(result.reusedMessages == 0)
        #expect(result.reprefilledTokens == current.tokens.reduce(0, +))
    }

    /// Append-only growth (the frozen-prefix contract): every previous
    /// message matches, so only the new tail re-prefills.
    @Test func reuse_appendOnlyGrowthReusesWholePreviousTranscript() {
        let turn1: [ChatMessage] = [
            ChatMessage(role: "user", content: "[Memory]\nfact\n[/Memory]\n\nfirst question")
        ]
        let turn2 =
            turn1 + [
                ChatMessage(role: "assistant", content: "first answer"),
                ChatMessage(role: "user", content: "second question"),
            ]
        let prev = fingerprint(turn1)
        let current = fingerprint(turn2)
        let result = SessionToolStateStore.conversationReuse(
            previous: prev,
            current: current,
            staticPrefixMatched: true
        )
        #expect(result.reusedMessages == 1)
        #expect(result.reusedTokens == current.tokens[0])
        #expect(result.reprefilledTokens == current.tokens[1] + current.tokens[2])
    }

    /// The legacy injection divergence: turn 2 renders the previous user
    /// message with different bytes (its memory prefix vanished). Reuse
    /// stops at index 0 — the exact re-prefill the telemetry must surface.
    @Test func reuse_byteDivergenceAtHistoryMessageTruncatesReuse() {
        let turn1: [ChatMessage] = [
            ChatMessage(role: "user", content: "[Memory]\nfact\n[/Memory]\n\nfirst question")
        ]
        let turn2: [ChatMessage] = [
            ChatMessage(role: "user", content: "first question"),  // prefix vanished
            ChatMessage(role: "assistant", content: "first answer"),
            ChatMessage(role: "user", content: "[Memory]\nnew\n[/Memory]\n\nsecond question"),
        ]
        let result = SessionToolStateStore.conversationReuse(
            previous: fingerprint(turn1),
            current: fingerprint(turn2),
            staticPrefixMatched: true
        )
        #expect(result.reusedMessages == 0)
        #expect(result.reusedTokens == 0)
        #expect(result.reprefilledTokens == fingerprint(turn2).tokens.reduce(0, +))
    }

    /// Reuse is a contiguous-prefix property: a divergence in the middle
    /// ends the run even if later messages match again.
    @Test func reuse_stopsAtFirstDivergenceEvenIfTailMatches() {
        let prev = fingerprint([
            ChatMessage(role: "user", content: "q1"),
            ChatMessage(role: "assistant", content: "a1"),
            ChatMessage(role: "user", content: "q2"),
        ])
        let current = fingerprint([
            ChatMessage(role: "user", content: "q1"),
            ChatMessage(role: "assistant", content: "a1 EDITED"),
            ChatMessage(role: "user", content: "q2"),
        ])
        let result = SessionToolStateStore.conversationReuse(
            previous: prev,
            current: current,
            staticPrefixMatched: true
        )
        #expect(result.reusedMessages == 1)
        #expect(result.reusedTokens == current.tokens[0])
    }

    /// A static system+tools prefix change re-prefills the whole stream —
    /// conversation overlap cannot be reused past a rewritten prefix.
    @Test func reuse_staticPrefixMismatchZeroesReuse() {
        let messages = [ChatMessage(role: "user", content: "same bytes")]
        let result = SessionToolStateStore.conversationReuse(
            previous: fingerprint(messages),
            current: fingerprint(messages),
            staticPrefixMatched: false
        )
        #expect(result.reusedTokens == 0)
        #expect(result.reusedMessages == 0)
        #expect(result.reprefilledTokens == fingerprint(messages).tokens.reduce(0, +))
    }

    // MARK: - recordSend integration (actor state across two turns)

    /// Two-turn flow through the real store entry point: turn 1 is all
    /// prefill; turn 2 with identical hint + append-only conversation
    /// reuses turn 1's whole transcript (leading system message excluded —
    /// it belongs to the static-prefix row). Uses a unique session id so
    /// parallel tests can't interfere; invalidation clears the fingerprint.
    @Test func recordSend_twoTurnFlowReportsAppendOnlyReuse() async {
        let sid = "conv-reuse-\(UUID().uuidString)"
        let system = ChatMessage(role: "system", content: "static prefix")
        let u1 = ChatMessage(role: "user", content: "[Memory]\nf\n[/Memory]\n\nq1")
        let turn1: [ChatMessage] = [system, u1]

        let first = await SessionToolStateStore.shared.recordSend(
            sessionId: sid,
            cacheHint: "hint-A",
            trace: nil,
            conversation: turn1
        )
        #expect(first?.reusedTokens == 0)
        #expect(first?.reusedMessages == 0)

        let turn2 =
            turn1 + [
                ChatMessage(role: "assistant", content: "a1"),
                ChatMessage(role: "user", content: "q2"),
            ]
        let second = await SessionToolStateStore.shared.recordSend(
            sessionId: sid,
            cacheHint: "hint-A",
            trace: nil,
            conversation: turn2
        )
        // Turn 1's user message (the only non-system message) is reused in
        // full; only the new exchange re-prefills.
        #expect(second?.reusedMessages == 1)
        #expect(second?.reusedTokens == ContextBudgetManager.estimateTokens(forMessage: u1))
        #expect((second?.reprefilledTokens ?? 0) > 0)

        // A hint flip (static prefix rewrite) zeroes conversation reuse
        // even with identical history bytes.
        let third = await SessionToolStateStore.shared.recordSend(
            sessionId: sid,
            cacheHint: "hint-B",
            trace: nil,
            conversation: turn2
        )
        #expect(third?.reusedTokens == 0)
        #expect(third?.reusedMessages == 0)

        await SessionToolStateStore.shared.invalidate(sid)
    }
}
