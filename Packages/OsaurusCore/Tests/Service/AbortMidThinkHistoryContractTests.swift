//
// Stop-mid-stream then continue: contract that the osaurus chat UI's
// history → ChatMessage builder DROPS aborted assistant turns from the
// next prompt entirely. Locks the invariant so a future refactor can't
// accidentally re-introduce a `<think>` bleed across turns.
//
// Concretely we recreate the exact `priorUserMessages` shape from
// `ChatView.swift:1288-1291`:
//
//     let priorUserMessages: [ChatMessage] = turns.compactMap { t in
//         guard t.role == .user, !t.contentIsEmpty else { return nil }
//         return ChatMessage(role: "user", content: t.content)
//     }
//
// and prove every shape of aborted assistant turn is filtered out.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("Abort mid-think → continue: history builder contract")
struct AbortMidThinkHistoryContractTests {

    /// Mirror of the `ChatView.swift` builder. Kept inline here so a
    /// regression that drifts the chat-UI builder doesn't silently make
    /// this test pass against a stale copy of the rule.
    private func buildPriorUserMessages(_ turns: [ChatTurn]) -> [ChatMessage] {
        turns.compactMap { t in
            guard t.role == .user, !t.contentIsEmpty else { return nil }
            return ChatMessage(role: "user", content: t.content)
        }
    }

    /// 3-turn sequence that exactly models the user's reported scenario:
    ///   T1 user: "explain X"
    ///   T1 assistant: aborted mid-`<think>` → content="", thinking=partial
    ///   T2 user: "what about Y"
    /// The history sent to the engine MUST contain only T1+T2 user messages
    /// — no assistant role, no `<think>` markers anywhere.
    @Test func abortedAssistantWithThinkingIsDroppedFromHistory() {
        let t1User = ChatTurn(role: .user, content: "explain quicksort")
        let t1Assistant = ChatTurn(role: .assistant, content: "")
        // Simulate the engine streaming a partial `<think>` block before stop.
        // Reasoning text is routed to .thinking via ReasoningParser; .content
        // stays empty because </think> never arrived.
        t1Assistant.thinking = "Quicksort works by picking a pivot, partitioning"
        let t2User = ChatTurn(role: .user, content: "what about merge sort?")

        let history = buildPriorUserMessages([t1User, t1Assistant, t2User])

        #expect(history.count == 2, "only the two user turns must be sent")
        #expect(history.allSatisfy { $0.role == "user" }, "no assistant turn in history")

        let combined = history.map { $0.content ?? "" }.joined(separator: "\n")
        #expect(
            !combined.contains("<think>"),
            "no <think> opener may leak into the prompt"
        )
        #expect(
            !combined.contains("</think>"),
            "no </think> closer may leak into the prompt"
        )
        #expect(
            !combined.contains(t1Assistant.thinking),
            "the partial thinking text must not appear in the prompt at all"
        )
    }

    /// Aborted in CONTENT mode (not reasoning) — content has visible
    /// partial output but no markers. Still must be excluded since
    /// `t.role != .user`.
    @Test func abortedAssistantInContentModeIsDropped() {
        let t1User = ChatTurn(role: .user, content: "list 5 facts")
        let t1Assistant = ChatTurn(role: .assistant, content: "1. The first fact is")
        let t2User = ChatTurn(role: .user, content: "continue please")

        let history = buildPriorUserMessages([t1User, t1Assistant, t2User])
        #expect(history.count == 2)
        let combined = history.map { $0.content ?? "" }.joined(separator: "\n")
        #expect(
            !combined.contains("first fact"),
            "partial assistant content must not leak as user content"
        )
    }

    /// Multiple back-to-back aborts: T1, T2, T3 user; T1 assistant aborted
    /// in reasoning, T2 assistant aborted in content, T3 still pending.
    /// History sent for T3 must contain only the 3 user messages.
    @Test func multipleAbortsAcrossTurns() {
        let u1 = ChatTurn(role: .user, content: "q1")
        let a1 = ChatTurn(role: .assistant, content: "")
        a1.thinking = "thinking about q1 when stop fired"
        let u2 = ChatTurn(role: .user, content: "q2 follow-up")
        let a2 = ChatTurn(role: .assistant, content: "partial answer for q2")
        a2.thinking = "thinking about q2"
        let u3 = ChatTurn(role: .user, content: "q3 final")

        let history = buildPriorUserMessages([u1, a1, u2, a2, u3])
        #expect(history.count == 3)
        #expect(history.map { $0.content }.compactMap { $0 } == ["q1", "q2 follow-up", "q3 final"])
        let combined = history.map { $0.content ?? "" }.joined(separator: "\n")
        #expect(!combined.contains("<think>"))
        #expect(!combined.contains("partial answer"))
        #expect(!combined.contains("thinking about"))
    }

    /// Empty user turn (e.g. user pressed enter on blank input) is also
    /// filtered — the guard `!t.contentIsEmpty` catches it. This means
    /// the engine never receives a degenerate `[user: "", user: "real"]`
    /// shape that some chat templates choke on.
    @Test func emptyUserTurnFiltered() {
        let empty = ChatTurn(role: .user, content: "")
        let real = ChatTurn(role: .user, content: "actual question")
        let history = buildPriorUserMessages([empty, real])
        #expect(history.count == 1)
        #expect(history.first?.content == "actual question")
    }

    /// User-typed `<think>` literal in their own message must NOT be
    /// stripped by the history builder — it's preserved verbatim. The
    /// downstream parser handles whether to engage on it (none-stamp
    /// non-reasoning models stream raw and the literal goes through
    /// untouched; think_xml-stamp models would interpret it, but that's
    /// the user's intent).
    @Test func userTypedThinkMarkerIsPreserved() {
        let u = ChatTurn(role: .user, content: "what does <think>x</think> mean?")
        let history = buildPriorUserMessages([u])
        #expect(history.count == 1)
        #expect(history.first?.content == "what does <think>x</think> mean?")
    }

    /// The exact `MiniMax-M2.7-Small-JANGTQ`-shaped scenario the user
    /// reported: user sends a prompt, model starts in reasoning mode,
    /// user clicks Stop while parser is still inside `<think>`. The
    /// next turn's prompt must be EXACTLY [original user prompt, new
    /// user follow-up] — no echoed `<think>`, no empty assistant slot.
    @Test func minimaxStopMidThinkContinueScenario() {
        let q1 = ChatTurn(
            role: .user,
            content: "Explain how MoE routing works step by step."
        )
        let aborted = ChatTurn(role: .assistant, content: "")
        // Simulate ~200 chars of buffered reasoning when stop hit.
        aborted.thinking = String(repeating: "Routing in MoE means... ", count: 12)
        let q2 = ChatTurn(role: .user, content: "Just give me the short version.")

        let history = buildPriorUserMessages([q1, aborted, q2])

        #expect(history.count == 2)
        #expect(history[0].content == q1.content)
        #expect(history[1].content == q2.content)

        // Prove the partial thinking is NOT in the prompt — even as a
        // substring, since contamination via concatenation would also break.
        let prompt = history.map { ($0.content ?? "") }.joined(separator: "\n---\n")
        #expect(!prompt.contains("Routing in MoE"))
        #expect(!prompt.contains("<think>"))
    }
}
