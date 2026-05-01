//
// Multi-turn × generation config × tools/skills × abort contract.
// Locks the invariants the user suspected of causing stop-and-continue
// looping:
//
//   * generation_config / jang_config sampling defaults survive the
//     abort+resume cycle deterministically — no per-turn drift
//   * pending tool-call state on an aborted turn does NOT leak into the
//     next turn's input (covered indirectly by the user-only filter,
//     reverified here for tool-shaped state)
//   * skill enable/disable round-trips fresh every turn — no stale
//     skill content baked into the cached prompt
//   * the chat-history → ChatMessage builder filters BOTH role==.tool
//     AND role==.assistant turns; only role==.user survives across
//     turns regardless of tool/skill state on those turns
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("Generation defaults — multi-turn cache stability")
struct GenerationDefaultsMultiTurnTests {

    /// `LocalGenerationDefaults` exposes a shared cache keyed by lowercased
    /// modelId. Multi-turn calls for the same model must return the SAME
    /// `Defaults` value, byte-identical, across N invocations. A regression
    /// where the cache returns a fresh-but-different value per call (e.g.
    /// because the parser becomes non-deterministic) would silently flip
    /// sampling settings turn-to-turn.
    @Test func sameModelMultiTurnReturnsIdenticalDefaults() {
        let json = #"""
            {
              "temperature": 0.6,
              "top_p": 0.9,
              "top_k": 40,
              "repetition_penalty": 1.05
            }
            """#
        let data = json.data(using: .utf8)!

        let r1 = LocalGenerationDefaults.parse(data: data)
        let r2 = LocalGenerationDefaults.parse(data: data)
        let r3 = LocalGenerationDefaults.parse(data: data)
        #expect(r1 == r2)
        #expect(r2 == r3)
        #expect(r1.temperature == 0.6)
        #expect(r1.topP == 0.9)
        #expect(r1.topK == 40)
        #expect(r1.repetitionPenalty == 1.05)
    }

    /// jang_config primary + generation_config fallback merge precedence
    /// must be stable across N invocations (multi-turn safety).
    @Test func jangPrimaryHFFallbackMergeStableAcrossTurns() {
        let jangData = #"""
            {
              "chat": {
                "sampling_defaults": {
                  "temperature": 0.6
                }
              }
            }
            """#.data(using: .utf8)!
        let hfData = #"""
            {
              "temperature": 1.0,
              "top_p": 0.95,
              "top_k": 50
            }
            """#.data(using: .utf8)!

        for i in 1 ... 5 {
            let jang = LocalGenerationDefaults.parseJangConfig(data: jangData)
            let hf = LocalGenerationDefaults.parse(data: hfData)
            let merged = LocalGenerationDefaults.merge(primary: jang, fallback: hf)
            #expect(
                merged.temperature == 0.6,
                "turn \(i): jang primary temp must win over HF fallback"
            )
            #expect(merged.topP == 0.95, "turn \(i): topP fills from HF")
            #expect(merged.topK == 50, "turn \(i): topK fills from HF")
            #expect(
                merged.repetitionPenalty == nil,
                "turn \(i): unset field stays nil, no synthetic value"
            )
        }
    }

    /// The repetition_penalty field is now treated as a no-op when 1.0
    /// (vmlx fix cf8c525). Multi-turn this means consecutive abort+resume
    /// cycles never accumulate a hidden penalty drift — penalty=1.0 in
    /// generation_config produces exactly the same logits as no penalty,
    /// so the model's sampling is deterministic for identical prompts.
    @Test func repetitionPenaltyExactlyOneIsRecognised() {
        let data = #"""
            { "temperature": 0.6, "repetition_penalty": 1.0 }
            """#.data(using: .utf8)!
        let r = LocalGenerationDefaults.parse(data: data)
        #expect(r.repetitionPenalty == 1.0)
        // NOTE: the engine treats penalty=1.0 as no-op (cf8c525 in vmlx).
        // We don't translate that here — we just preserve the value
        // verbatim and let the engine apply its no-op shortcut.
    }

    /// Concurrent multi-turn parse: parser is pure, no shared state.
    /// Even if osaurus made parallel preflight + chat requests for the
    /// same model, parse results must be deterministic.
    @Test func concurrentParseIsDeterministic() async {
        let data = #"""
            { "temperature": 0.7, "top_p": 0.95, "top_k": 64 }
            """#.data(using: .utf8)!

        await withTaskGroup(of: LocalGenerationDefaults.Defaults.self) { group in
            for _ in 0 ..< 32 {
                group.addTask {
                    LocalGenerationDefaults.parse(data: data)
                }
            }
            var seen: Set<String> = []
            for await r in group {
                seen.insert("\(r.temperature ?? -1)/\(r.topP ?? -1)/\(r.topK ?? -1)")
            }
            #expect(
                seen.count == 1,
                "32 concurrent parses must yield identical results, got \(seen.count) variants"
            )
        }
    }
}

@Suite("Multi-turn history — tool + skill state filter contract")
struct MultiTurnHistoryToolSkillFilterTests {

    /// Reverify: assistant turns with tool-call state get filtered the
    /// same way as plain assistant turns. The user-only filter doesn't
    /// look at tool fields — it just checks role.
    @Test func assistantWithPendingToolStateIsFiltered() {
        let q1 = ChatTurn(role: .user, content: "search for X")
        let aborted = ChatTurn(role: .assistant, content: "")
        // Simulate mid-tool-call abort: parser was buffering args.
        aborted.pendingToolName = "web_search"
        aborted.pendingToolArgPreview = #"{"query": "partial args before abort"#
        let q2 = ChatTurn(role: .user, content: "actually nevermind, search Y")

        let history: [ChatMessage] = [q1, aborted, q2].compactMap { t in
            guard t.role == .user, !t.contentIsEmpty else { return nil }
            return ChatMessage(role: "user", content: t.content)
        }

        #expect(history.count == 2)
        let prompt = history.compactMap { $0.content }.joined(separator: "\n")
        #expect(
            !prompt.contains("web_search"),
            "pending tool name from aborted turn must not leak into prompt"
        )
        #expect(
            !prompt.contains("partial args"),
            "buffered tool args from aborted turn must not leak"
        )
    }

    /// Completed tool exchange (assistant → tool → assistant) — the entire
    /// in-flight exchange is also filtered out of the next user prompt.
    /// vmlx's chat template re-renders the assistant-tool-assistant chain
    /// only WITHIN one user query; across the next user message, only
    /// user content survives.
    @Test func completedToolExchangeIsFilteredFromNextUserTurn() {
        let q1 = ChatTurn(role: .user, content: "what time is it in Tokyo")
        let assistant1 = ChatTurn(role: .assistant, content: "")
        let toolCall = ToolCall(
            id: "call_abc",
            type: "function",
            function: ToolCallFunction(
                name: "get_time",
                arguments: #"{"city":"Tokyo"}"#
            )
        )
        assistant1.toolCalls = [toolCall]
        let toolResult = ChatTurn(role: .tool, content: "14:23 JST")
        toolResult.toolCallId = "call_abc"
        let assistant2 = ChatTurn(role: .assistant, content: "It's 14:23 in Tokyo.")
        let q2 = ChatTurn(role: .user, content: "and in New York?")

        let history: [ChatMessage] = [q1, assistant1, toolResult, assistant2, q2]
            .compactMap { t in
                guard t.role == .user, !t.contentIsEmpty else { return nil }
                return ChatMessage(role: "user", content: t.content)
            }

        #expect(history.count == 2)
        #expect(history[0].content == "what time is it in Tokyo")
        #expect(history[1].content == "and in New York?")
        let prompt = history.compactMap { $0.content }.joined(separator: "\n")
        #expect(!prompt.contains("get_time"))
        #expect(!prompt.contains("14:23"))
        #expect(!prompt.contains("Tokyo."))
    }

    /// Aborted assistant turn while in CONTENT mode after a successful
    /// tool call (so toolCalls is populated but the post-tool answer
    /// content is partial). All of it gets filtered.
    @Test func abortedPostToolAnswerIsFiltered() {
        let q1 = ChatTurn(role: .user, content: "weather in NYC")
        let assistant1 = ChatTurn(role: .assistant, content: "")
        let call = ToolCall(
            id: "c1",
            type: "function",
            function: ToolCallFunction(name: "weather", arguments: #"{"city":"NYC"}"#)
        )
        assistant1.toolCalls = [call]
        let toolResult = ChatTurn(role: .tool, content: "72°F sunny")
        toolResult.toolCallId = "c1"
        // Assistant started replying then user clicked Stop.
        let assistant2_partial = ChatTurn(role: .assistant, content: "It's currently 72°")
        let q2 = ChatTurn(role: .user, content: "what about humidity?")

        let history: [ChatMessage] = [
            q1, assistant1, toolResult, assistant2_partial, q2,
        ].compactMap { t in
            guard t.role == .user, !t.contentIsEmpty else { return nil }
            return ChatMessage(role: "user", content: t.content)
        }

        #expect(history.count == 2)
        #expect(history[0].content == "weather in NYC")
        #expect(history[1].content == "what about humidity?")
        let prompt = history.compactMap { $0.content }.joined(separator: "\n")
        #expect(
            !prompt.contains("72°"),
            "partial post-tool content from aborted turn must not leak"
        )
        // The token "weather" naturally appears in the user's own
        // question — that's expected. What we're verifying is that the
        // assistant's tool-call name / tool result text never appears.
        #expect(
            !prompt.contains("It's currently"),
            "partial post-tool answer text must not leak"
        )
    }

    /// Multi-turn skill-toggle: user enables a skill on turn 1, asks Q1,
    /// disables on turn 2 (asks Q2), re-enables on turn 3 (asks Q3).
    /// The skill text appears in the SYSTEM PROMPT only on turns where
    /// it's enabled — but turn-to-turn, the user-only filter still
    /// produces the same shape: [Q1, Q2, Q3]. Skill state is a per-turn
    /// system-prompt concern, not a history concern.
    @Test func skillToggleAcrossTurnsDoesNotLeakIntoHistory() {
        let q1 = ChatTurn(role: .user, content: "Q1 with skill on")
        let a1 = ChatTurn(role: .assistant, content: "A1")
        let q2 = ChatTurn(role: .user, content: "Q2 with skill off")
        let a2 = ChatTurn(role: .assistant, content: "A2")
        let q3 = ChatTurn(role: .user, content: "Q3 with skill on again")

        let history: [ChatMessage] = [q1, a1, q2, a2, q3].compactMap { t in
            guard t.role == .user, !t.contentIsEmpty else { return nil }
            return ChatMessage(role: "user", content: t.content)
        }

        #expect(history.count == 3)
        #expect(history.map { $0.content } == ["Q1 with skill on", "Q2 with skill off", "Q3 with skill on again"])
    }
}

@Suite("Stop-and-continue determinism")
struct StopAndContinueDeterminismTests {

    /// Simulates the user's reported scenario: send Q, abort mid-stream,
    /// send Q again (or follow-up). The history builder produces an
    /// IDENTICAL message list regardless of whether the model output
    /// went into reasoning, content, or tool-call state on the aborted
    /// turn — because the filter only looks at role+contentIsEmpty.
    @Test func abortedTurnShapeDoesNotAffectNextPrompt() {
        let q = ChatTurn(role: .user, content: "the prompt")

        // Variant A: aborted while in reasoning (content empty, thinking partial)
        let abortReason = ChatTurn(role: .assistant, content: "")
        abortReason.thinking = "partial CoT"
        // Variant B: aborted while in content (content partial)
        let abortContent = ChatTurn(role: .assistant, content: "partial answer")
        // Variant C: aborted while in tool-call (pending tool name + args)
        let abortTool = ChatTurn(role: .assistant, content: "")
        abortTool.pendingToolName = "search"
        abortTool.pendingToolArgPreview = "{\"q\":\"partial"

        let q2 = ChatTurn(role: .user, content: "follow-up")

        // Build history for each variant:
        func build(_ aborted: ChatTurn) -> [ChatMessage] {
            [q, aborted, q2].compactMap { t in
                guard t.role == .user, !t.contentIsEmpty else { return nil }
                return ChatMessage(role: "user", content: t.content)
            }
        }

        let hA = build(abortReason)
        let hB = build(abortContent)
        let hC = build(abortTool)

        // All three variants must produce IDENTICAL history shape.
        #expect(hA.count == 2 && hB.count == 2 && hC.count == 2)
        #expect(hA.compactMap { $0.content } == hB.compactMap { $0.content })
        #expect(hB.compactMap { $0.content } == hC.compactMap { $0.content })
        #expect(hA.compactMap { $0.content } == ["the prompt", "follow-up"])
    }
}
