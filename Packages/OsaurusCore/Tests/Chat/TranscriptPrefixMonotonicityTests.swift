//
//  TranscriptPrefixMonotonicityTests.swift
//  osaurusTests
//
//  Cross-turn KV-prefix contract: the message array sent on turn N must be
//  a strict prefix — role and content bytes — of the array sent on turn
//  N+1. The static system+tools prefix is covered by PrefixHashTests /
//  SessionPreflightCacheTests; this suite covers the CONVERSATION part,
//  which regressed silently when per-turn memory / screen-context
//  injection rewrote the previous user message between turns (turn N sent
//  `u_N + [Memory]`, turn N+1 sent `u_N` clean), re-prefilling the whole
//  last exchange every turn.
//
//  The simulation uses the exact primitives the chat surface now uses:
//  a frozen `injectedContextPrefix` per user turn, rendered through
//  `ChatSession.applyingFrozenInjectedPrefix`, plus the sticky
//  `CompactionWatermark` that must NOT reset across append-only growth.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("Transcript prefix monotonicity")
struct TranscriptPrefixMonotonicityTests {

    /// Byte-level equality of the shared prefix: every message of turn N's
    /// outbound array must reappear at the same index in turn N+1's array
    /// with identical role, content, and tool-call linkage.
    private func expectStrictPrefix(_ earlier: [ChatMessage], of later: [ChatMessage]) {
        #expect(earlier.count < later.count, "turn N+1 must extend turn N, not replace it")
        for (idx, msg) in earlier.enumerated() {
            #expect(later[idx].role == msg.role, "role diverged at index \(idx)")
            #expect(later[idx].content == msg.content, "content bytes diverged at index \(idx)")
            #expect(later[idx].tool_call_id == msg.tool_call_id, "tool linkage diverged at index \(idx)")
        }
    }

    /// Render a simulated chat history the way `turnToMessage` now does:
    /// system prompt first, user turns with their frozen prefix replayed,
    /// assistant turns as-is.
    @MainActor
    private func render(
        system: String,
        turns: [(role: String, content: String, frozenPrefix: String?)]
    ) -> [ChatMessage] {
        var msgs: [ChatMessage] = [ChatMessage(role: "system", content: system)]
        for turn in turns {
            if turn.role == "user" {
                let base = ChatMessage(role: "user", content: turn.content)
                msgs.append(ChatSession.applyingFrozenInjectedPrefix(turn.frozenPrefix, to: base))
            } else {
                msgs.append(ChatMessage(role: turn.role, content: turn.content))
            }
        }
        return msgs
    }

    /// Two consecutive turns with memory + screen context on: turn N's
    /// outbound transcript must be a strict byte-prefix of turn N+1's.
    /// This is the test that would have caught the injection divergence.
    @Test @MainActor func turnN_isStrictBytePrefixOfTurnN1_withMemoryAndScreenContext() {
        let system = "You are the local agent."
        let screen = "[Screen Context]\nDoing: In Safari\n[/Screen Context]"

        // Turn 1: the send path freezes memory+screen onto u1 at send time.
        let prefix1 = SystemPromptComposer.composeInjectedUserPrefix(
            memorySection: "fact for turn one",
            screenContext: screen
        )
        let turn1 = render(
            system: system,
            turns: [("user", "first question", prefix1)]
        )

        // Turn 2: history is append-only; u1 keeps its frozen prefix, the
        // new turn freezes its own (fresh memory recall, same frozen
        // screen-context snapshot — it is per-session).
        let prefix2 = SystemPromptComposer.composeInjectedUserPrefix(
            memorySection: "different fact for turn two",
            screenContext: screen
        )
        let turn2 = render(
            system: system,
            turns: [
                ("user", "first question", prefix1),
                ("assistant", "first answer", nil),
                ("user", "second question", prefix2),
            ]
        )

        expectStrictPrefix(turn1, of: turn2)

        // And the divergence the fix removes: rendering u1 CLEAN on turn 2
        // (the legacy behavior — injection rode only the latest message)
        // breaks the byte prefix at u1.
        let legacyTurn2 = render(
            system: system,
            turns: [
                ("user", "first question", nil),
                ("assistant", "first answer", nil),
                ("user", "second question", prefix2),
            ]
        )
        #expect(legacyTurn2[1].content != turn1[1].content)
    }

    /// Multi-turn: the property holds transitively across three turns with
    /// changing memory, including a turn without any injected context
    /// (memory recall can come back empty).
    @Test @MainActor func monotonicityHoldsAcrossThreeTurns_withGapTurn() {
        let system = "sys"
        let p1 = SystemPromptComposer.composeInjectedUserPrefix(
            memorySection: "m1",
            screenContext: nil
        )
        let p3 = SystemPromptComposer.composeInjectedUserPrefix(
            memorySection: "m3",
            screenContext: nil
        )

        var history: [(role: String, content: String, frozenPrefix: String?)] = [
            ("user", "q1", p1)
        ]
        let t1 = render(system: system, turns: history)

        history += [("assistant", "a1", nil), ("user", "q2", nil)]  // no memory this turn
        let t2 = render(system: system, turns: history)

        history += [("assistant", "a2", nil), ("user", "q3", p3)]
        let t3 = render(system: system, turns: history)

        expectStrictPrefix(t1, of: t2)
        expectStrictPrefix(t2, of: t3)
        expectStrictPrefix(t1, of: t3)
    }

    /// The sticky compaction watermark must survive append-only growth of
    /// the frozen-prefix transcript: identities recorded on turn N still
    /// match on turn N+1, so verbatim/summarize/drop decisions replay
    /// instead of resetting (a reset recomputes trims and can rewrite
    /// mid-transcript bytes). Before the fix, the injected prefix vanished
    /// from u_N between turns, changing its identity hash and resetting
    /// the watermark every turn.
    @Test @MainActor func watermark_decisionsSurviveAppendOnlyGrowth() {
        let system = "sys"
        let p1 = SystemPromptComposer.composeInjectedUserPrefix(
            memorySection: "m1",
            screenContext: nil
        )
        let p2 = SystemPromptComposer.composeInjectedUserPrefix(
            memorySection: "m2",
            screenContext: nil
        )

        let turn1 = render(system: system, turns: [("user", "q1", p1)])
        let turn2 = render(
            system: system,
            turns: [
                ("user", "q1", p1),
                ("assistant", "a1", nil),
                ("user", "q2", p2),
            ]
        )

        // Big budget: nothing trims, every sent message is recorded verbatim.
        let manager = ContextBudgetManager(contextLength: 128_000)
        let watermark = CompactionWatermark()

        let out1 = manager.trimMessagesReportingOverflow(turn1, watermark: watermark)
        #expect(out1.messages.map(\.content) == turn1.map(\.content))

        // Turn 2 validates identities against the grown history. If the
        // frozen prefix had vanished (legacy divergence), index 1's identity
        // would mismatch and reset every decision.
        let out2 = manager.trimMessagesReportingOverflow(turn2, watermark: watermark)
        #expect(out2.messages.map(\.content) == turn2.map(\.content))

        // The turn-1 messages must still carry their verbatim markers —
        // proof the watermark did NOT reset on turn 2.
        for idx in turn1.indices {
            switch watermark.decision(at: idx) {
            case .verbatim: break
            default: Issue.record("watermark reset: index \(idx) lost its verbatim marker")
            }
        }
    }

    /// Same property for the HTTP/plugin ledger path: two consecutive
    /// requests through `applyFrozenMemoryPrefixes` produce monotonic
    /// transcripts even though the client resends clean history.
    @Test func ledgerPath_requestN_isStrictBytePrefixOfRequestN1() {
        var ledger: [String: String] = [:]

        var request1: [ChatMessage] = [
            ChatMessage(role: "system", content: "sys"),
            ChatMessage(role: "user", content: "q1"),
        ]
        if let rec = SystemPromptComposer.applyFrozenMemoryPrefixes(
            memorySection: "m1",
            frozen: ledger,
            into: &request1
        ) {
            ledger[rec.key] = rec.prefix
        }

        var request2: [ChatMessage] = [
            ChatMessage(role: "system", content: "sys"),
            ChatMessage(role: "user", content: "q1"),
            ChatMessage(role: "assistant", content: "a1"),
            ChatMessage(role: "user", content: "q2"),
        ]
        if let rec = SystemPromptComposer.applyFrozenMemoryPrefixes(
            memorySection: "m2",
            frozen: ledger,
            into: &request2
        ) {
            ledger[rec.key] = rec.prefix
        }

        #expect(request1.count < request2.count)
        for (idx, msg) in request1.enumerated() {
            #expect(request2[idx].role == msg.role, "role diverged at index \(idx)")
            #expect(request2[idx].content == msg.content, "content bytes diverged at index \(idx)")
        }
    }
}
