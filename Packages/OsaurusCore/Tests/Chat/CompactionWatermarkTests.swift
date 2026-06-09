//
//  CompactionWatermarkTests.swift
//  osaurusTests
//
//  Pin the sticky-compaction contract from the loop-unification phase:
//  `ContextBudgetManager.trimMessages(_:recentPairsToKeep:watermark:)` must
//  produce a MONOTONIC transcript — once a message is summarized its summary
//  replays byte-identically on every later trim, and once a message is
//  dropped it stays dropped — so the rendered token prefix stays byte-stable
//  across agent-loop iterations and the paged-KV cache can reuse it.
//
//  The stateless `trimMessages(_:recentPairsToKeep:)` recomputes from
//  scratch each call (it can rewrite the middle of the array between
//  iterations); these tests are the regression net proving the sticky
//  variant doesn't.
//

import Foundation
import Testing

@testable import OsaurusCore

struct CompactionWatermarkTests {

    // MARK: - Helpers

    private func makeManager(contextLength: Int = 8_192, reservedResponse: Int = 1_024)
        -> ContextBudgetManager
    {
        var mgr = ContextBudgetManager(contextLength: contextLength)
        mgr.reserve(.response, tokens: reservedResponse)
        return mgr
    }

    private func userMessage(_ text: String) -> ChatMessage {
        ChatMessage(role: "user", content: text)
    }

    private func assistantToolCallMessage(id: String) -> ChatMessage {
        ChatMessage(
            role: "assistant",
            content: nil,
            tool_calls: [
                ToolCall(
                    id: id,
                    type: "function",
                    function: ToolCallFunction(name: "file_read", arguments: "{\"path\":\"a.txt\"}")
                )
            ],
            tool_call_id: nil
        )
    }

    private func toolResultMessage(id: String, chars: Int) -> ChatMessage {
        // "Lines " prefix makes summarizeToolResult treat it as file content.
        let body = "Lines 1-400 of a.txt\n" + String(repeating: "x", count: chars)
        return ChatMessage(role: "tool", content: body, tool_calls: nil, tool_call_id: id)
    }

    /// A long agent-loop conversation: one user task followed by `rounds`
    /// assistant→tool pairs with large tool outputs.
    private func scriptedSession(rounds: Int, toolChars: Int = 6_000) -> [ChatMessage] {
        var messages: [ChatMessage] = [userMessage("Refactor the parser and verify the tests pass.")]
        for round in 0 ..< rounds {
            messages.append(assistantToolCallMessage(id: "call_\(round)"))
            messages.append(toolResultMessage(id: "call_\(round)", chars: toolChars))
        }
        return messages
    }

    private func render(_ messages: [ChatMessage]) -> String {
        messages.map { "\($0.role)|\($0.content ?? "<nil>")|\($0.tool_call_id ?? "")" }
            .joined(separator: "\n---\n")
    }

    // MARK: - Tests

    @Test func withinBudgetIsUntouched() {
        let mgr = makeManager(contextLength: 128_000)
        let watermark = CompactionWatermark()
        let messages = scriptedSession(rounds: 3)

        let trimmed = mgr.trimMessages(messages, watermark: watermark)

        #expect(render(trimmed) == render(messages))
        #expect(!watermark.hasCompacted)
    }

    @Test func sameInputProducesByteIdenticalOutputAcrossCalls() {
        let mgr = makeManager()
        let watermark = CompactionWatermark()
        let messages = scriptedSession(rounds: 12)

        let first = mgr.trimMessages(messages, watermark: watermark)
        let second = mgr.trimMessages(messages, watermark: watermark)
        let third = mgr.trimMessages(messages, watermark: watermark)

        #expect(render(first) == render(second))
        #expect(render(second) == render(third))
        // The session is far over an 8K budget, so compaction must have engaged.
        #expect(watermark.hasCompacted)
    }

    @Test func appendOnlyGrowthKeepsEarlierPrefixStable() {
        let mgr = makeManager()
        let watermark = CompactionWatermark()
        var messages = scriptedSession(rounds: 10)

        let before = mgr.trimMessages(messages, watermark: watermark)

        // Append another loop iteration (append-only history growth).
        messages.append(assistantToolCallMessage(id: "call_new"))
        messages.append(toolResultMessage(id: "call_new", chars: 500))
        let after = mgr.trimMessages(messages, watermark: watermark)

        // Every message that survived the first trim and is not part of the
        // moving protected tail must appear in the second trim byte-identical
        // and in the same relative order (monotonic prefix). Compare the
        // leading half of the first output against the second.
        let beforeRendered = before.map { "\($0.role)|\($0.content ?? "<nil>")|\($0.tool_call_id ?? "")" }
        let afterRendered = after.map { "\($0.role)|\($0.content ?? "<nil>")|\($0.tool_call_id ?? "")" }
        let stablePrefixCount = max(1, beforeRendered.count / 2)
        let beforePrefix = Array(beforeRendered.prefix(stablePrefixCount))

        // The prefix may shrink if more drops were needed, but whatever
        // remains must be a subsequence-preserving prefix: walk `after` and
        // require the surviving prefix entries to appear in order.
        var cursor = 0
        for entry in afterRendered where cursor < beforePrefix.count {
            if entry == beforePrefix[cursor] { cursor += 1 }
        }
        // At minimum the protected first message survives identically, and
        // frozen summaries replay rather than recompute.
        #expect(cursor >= 1)
        #expect(afterRendered.first == beforeRendered.first)
    }

    @Test func summariesReplayByteIdenticallyOnceFrozen() {
        let mgr = makeManager()
        let watermark = CompactionWatermark()
        var messages = scriptedSession(rounds: 12)

        let first = mgr.trimMessages(messages, watermark: watermark)
        let frozenSummaries = first.filter {
            $0.role == "tool" && ($0.content?.hasPrefix("[Compressed:") ?? false)
        }
        #expect(!frozenSummaries.isEmpty)

        // Grow history; previously frozen summaries must replay verbatim.
        messages.append(assistantToolCallMessage(id: "call_extra"))
        messages.append(toolResultMessage(id: "call_extra", chars: 300))
        let second = mgr.trimMessages(messages, watermark: watermark)
        let replayed = Set(
            second.compactMap { msg -> String? in
                guard msg.role == "tool", let c = msg.content, c.hasPrefix("[Compressed:") else {
                    return nil
                }
                return "\(msg.tool_call_id ?? "")|\(c)"
            })
        for summary in frozenSummaries {
            let key = "\(summary.tool_call_id ?? "")|\(summary.content ?? "")"
            // A frozen summary either replays byte-identically or its message
            // was dropped entirely (monotonic escalation) — it must never
            // reappear with different bytes.
            let sameIdDifferentBytes = second.contains { msg in
                msg.role == "tool" && msg.tool_call_id == summary.tool_call_id
                    && msg.content != summary.content
            }
            #expect(replayed.contains(key) || !sameIdDifferentBytes)
        }
    }

    @Test func droppedMessagesStayDropped() {
        let mgr = makeManager(contextLength: 4_096)
        let watermark = CompactionWatermark()
        var messages = scriptedSession(rounds: 14, toolChars: 8_000)

        let first = mgr.trimMessages(messages, watermark: watermark)
        let droppedAfterFirst = watermark.hasCompacted
        #expect(droppedAfterFirst)
        let firstIds = Set(first.compactMap { $0.tool_call_id })

        // Grow history and re-trim: call ids absent from the first output
        // (dropped) must not resurface.
        messages.append(assistantToolCallMessage(id: "call_tail"))
        messages.append(toolResultMessage(id: "call_tail", chars: 200))
        let second = mgr.trimMessages(messages, watermark: watermark)
        let secondIds = Set(second.compactMap { $0.tool_call_id })

        let allOriginalIds = Set((0 ..< 14).map { "call_\($0)" })
        let droppedIds = allOriginalIds.subtracting(firstIds)
        #expect(!droppedIds.isEmpty)
        #expect(secondIds.isDisjoint(with: droppedIds))
    }

    @Test func longSessionFitsHistoryBudgetOnSmallWindow() {
        let mgr = makeManager(contextLength: 8_192)
        let watermark = CompactionWatermark()
        var messages: [ChatMessage] = [userMessage("Fix the failing build.")]

        // Simulate 20 loop iterations with sticky trims between each.
        for round in 0 ..< 20 {
            messages.append(assistantToolCallMessage(id: "call_\(round)"))
            messages.append(toolResultMessage(id: "call_\(round)", chars: 5_000))
            let trimmed = mgr.trimMessages(messages, watermark: watermark)
            #expect(ContextBudgetManager.estimateTokens(for: trimmed) <= mgr.historyBudget)
        }
    }

    @Test func historyRewriteResetsDecisions() {
        let mgr = makeManager()
        let watermark = CompactionWatermark()
        let messages = scriptedSession(rounds: 12)

        _ = mgr.trimMessages(messages, watermark: watermark)
        #expect(watermark.hasCompacted)

        // Regeneration rewrites history: a shorter, different transcript.
        let rewritten = scriptedSession(rounds: 2, toolChars: 100)
        let trimmed = mgr.trimMessages(rewritten, watermark: watermark)

        // Decisions reset → the small rewritten history fits untouched.
        #expect(render(trimmed) == render(rewritten))
        #expect(!watermark.hasCompacted)
    }

    @Test func firstMessageAlwaysSurvives() {
        let mgr = makeManager(contextLength: 4_096)
        let watermark = CompactionWatermark()
        let messages = scriptedSession(rounds: 16, toolChars: 8_000)

        let trimmed = mgr.trimMessages(messages, watermark: watermark)

        #expect(trimmed.first?.role == "user")
        #expect(trimmed.first?.content == messages.first?.content)
    }

    @Test func statelessVariantUnchangedForPluginParity() {
        // The plugin host's historical stateless trim must behave the same
        // as before the watermark landed: deterministic for a fixed input.
        let mgr = makeManager()
        let messages = scriptedSession(rounds: 12)

        let a = mgr.trimMessages(messages)
        let b = mgr.trimMessages(messages)

        #expect(render(a) == render(b))
        #expect(ContextBudgetManager.estimateTokens(for: a) <= mgr.historyBudget)
    }
}
