//
//  AgentLoopBudgetTests.swift
//  osaurusTests
//
//  Pin the shared UI/runtime budget accounting (`AgentLoopBudget.assess`)
//  that drives FloatingInputCard's ratio / near-limit / hard-overflow
//  gating. The historical UI math diverged from the runtime (raw window
//  vs the 0.85 effective budget, assistant output counted as
//  non-compactable, no response reservation); these tests are the
//  parity contract.
//

import Foundation
import Testing

@testable import OsaurusCore

struct AgentLoopBudgetTests {

    private func breakdown(
        system: Int = 0,
        tools: Int = 0,
        conversation: Int = 0,
        input: Int = 0,
        output: Int = 0
    ) -> ContextBreakdown {
        var ctx: [ContextBreakdown.Entry] = []
        if system > 0 {
            ctx.append(.init(id: "platform", label: L("Platform"), tokens: system, tint: .indigo))
        }
        if tools > 0 {
            ctx.append(.init(id: "tools", label: L("Tools"), tokens: tools, tint: .orange))
        }
        var msgs: [ContextBreakdown.Entry] = []
        if conversation > 0 {
            msgs.append(.init(id: "conversation", label: L("Conversation"), tokens: conversation, tint: .gray))
        }
        if input > 0 {
            msgs.append(.init(id: "input", label: L("Input"), tokens: input, tint: .cyan))
        }
        if output > 0 {
            msgs.append(.init(id: "output", label: L("Output"), tokens: output, tint: .green))
        }
        return ContextBreakdown(context: ctx, messages: msgs, disable: nil)
    }

    @Test func ratioUsesEffectiveBudgetNotRawWindow() {
        // 10_000 window → effective 8_500. 8_000 tokens is 94% of the
        // effective budget (near limit) even though it's only 80% of the
        // raw window the old UI math used.
        let bd = breakdown(system: 4_000, conversation: 4_000)
        let assessment = AgentLoopBudget.assess(breakdown: bd, contextWindow: 10_000)
        let effective = ContextBudgetManager(contextLength: 10_000).effectiveBudget
        #expect(effective == 8_500)
        #expect(assessment.usageRatio != nil)
        #expect(abs((assessment.usageRatio ?? 0) - 8_000.0 / 8_500.0) < 0.001)
        #expect(assessment.nearLimit)
    }

    @Test func emptyBreakdownHasNilRatio() {
        let assessment = AgentLoopBudget.assess(breakdown: .zero, contextWindow: 10_000)
        #expect(assessment.usageRatio == nil)
        #expect(!assessment.nearLimit)
        #expect(!assessment.hardOverflow)
    }

    @Test func hardOverflowExcludesCompactableHistory() {
        // Huge conversation + output but a small fixed prefix: compaction
        // can always trim history, so the send must NOT be hard-gated.
        let bd = breakdown(system: 1_000, tools: 500, conversation: 50_000, input: 100, output: 20_000)
        let assessment = AgentLoopBudget.assess(breakdown: bd, contextWindow: 10_000)
        #expect(!assessment.hardOverflow)
        // The ratio still reflects the full estimate (way over).
        #expect((assessment.usageRatio ?? 0) > 1.0)
    }

    @Test func hardOverflowFiresWhenFixedPrefixAloneExceedsBudget() {
        // System prompt + tools + input alone exceed the effective budget:
        // no amount of history compaction can save this request.
        let bd = breakdown(system: 6_000, tools: 2_000, conversation: 100, input: 1_000)
        let assessment = AgentLoopBudget.assess(breakdown: bd, contextWindow: 10_000)
        #expect(assessment.hardOverflow)
    }

    @Test func responseReservationCountsTowardHardGateWithCap() {
        // Effective budget 8_500 → reservation capped at 2_125 (a quarter).
        // A fixed prefix of 7_000 + capped reservation crosses 8_500 even
        // though 7_000 alone would fit.
        let bd = breakdown(system: 7_000)
        let assessment = AgentLoopBudget.assess(breakdown: bd, contextWindow: 10_000)
        #expect(assessment.hardOverflow)
        // Without the reservation's contribution it would fit — prove the
        // cap is what crossed the line by shrinking the prefix below
        // effective - cap.
        let fits = AgentLoopBudget.assess(breakdown: breakdown(system: 6_000), contextWindow: 10_000)
        #expect(!fits.hardOverflow)
    }

    @Test func smallWindowModelsAreNotPermanentlyGatedByReservation() {
        // Foundation-class window (4_096 → effective 3_481): the default
        // 4_096 reservation exceeds the whole effective budget, so an
        // uncapped reservation would block EVERY send. The cap keeps a
        // modest prefix sendable.
        let bd = breakdown(system: 1_000, input: 200)
        let assessment = AgentLoopBudget.assess(
            breakdown: bd,
            contextWindow: AgentLoopBudget.foundationContextWindow
        )
        #expect(!assessment.hardOverflow)
    }

    @Test func zeroOrNegativeWindowYieldsEmptyAssessment() {
        let bd = breakdown(system: 1_000)
        #expect(AgentLoopBudget.assess(breakdown: bd, contextWindow: 0) == .empty)
        #expect(AgentLoopBudget.assess(breakdown: bd, contextWindow: -5) == .empty)
    }

    @Test func composeIterationMessagesAppendsNoticesTransientlyPostTrim() {
        // The canonical notice contract: trim first (system prefix kept
        // byte-stable), then notices ride at the END of the returned array
        // — and the caller's history array is never mutated.
        var mgr = ContextBudgetManager(contextLength: 128_000)
        mgr.reserve(.response, tokens: 1_024)
        let history: [ChatMessage] = [
            ChatMessage(role: "system", content: "You are a test agent."),
            ChatMessage(role: "user", content: "do the thing"),
            ChatMessage(role: "assistant", content: "working on it"),
        ]
        let notices = ["[System Notice] budget", "[System Notice] bias"]

        let composed = AgentLoopBudget.composeIterationMessages(
            history,
            notices: notices,
            manager: mgr,
            watermark: CompactionWatermark()
        )

        #expect(composed.messages.first?.role == "system")
        #expect(composed.messages.first?.content == "You are a test agent.")
        #expect(composed.messages.suffix(2).map { $0.content ?? "" } == notices)
        #expect(composed.messages.suffix(2).allSatisfy { $0.role == "user" })
        #expect(!composed.overBudget)
        // Transient: the input history is untouched (3 messages, no notices).
        #expect(history.count == 3)
        #expect(!history.contains { ($0.content ?? "").hasPrefix("[System Notice]") })
    }

    @Test func composeIterationMessagesWithoutManagerStillAppendsNotices() {
        let history = [ChatMessage(role: "user", content: "hi")]
        let composed = AgentLoopBudget.composeIterationMessages(
            history,
            notices: ["[System Notice] n"],
            manager: nil
        )
        #expect(composed.messages.count == 2)
        #expect(composed.messages.last?.content == "[System Notice] n")
        #expect(!composed.overBudget)
    }

    /// Regression (KV/prefix re-prefill after a tool call): a transient notice
    /// that rides the iteration AFTER a tool call must NOT be appended as a
    /// trailing *user* turn. Chat templates that gate the assistant reasoning
    /// rail on "the last user query" (Qwen3.x `last_query_index`) would then
    /// re-render the cached assistant tool-call turn WITHOUT its `<think>`
    /// scaffold, diverging from the stored KV prefix and forcing a full
    /// re-prefill ("kv cache set to 0"). The notice instead rides as tool-role
    /// environment feedback, so the genuine user query stays the last-query
    /// anchor and the KV prefix is reused.
    @Test func transientNoticeAfterToolResultRidesAsToolFeedback() {
        let history: [ChatMessage] = [
            ChatMessage(role: "system", content: "sys"),
            ChatMessage(role: "user", content: "list my models"),
            ChatMessage(
                role: "assistant",
                content: nil,
                tool_calls: [
                    ToolCall(
                        id: "call_1",
                        type: "function",
                        function: ToolCallFunction(name: "osaurus_list", arguments: "{}")
                    )
                ],
                tool_call_id: nil
            ),
            ChatMessage(
                role: "tool",
                content: "{\"ok\":true}",
                tool_calls: nil,
                tool_call_id: "call_1"
            ),
        ]
        let composed = AgentLoopBudget.composeIterationMessages(
            history,
            notices: ["[System Notice] Tool call budget: 1 of 2 remaining."],
            manager: nil
        )
        // Delivered as tool feedback (joined to the tool result), not a
        // trailing user turn.
        #expect(composed.messages.last?.role == "tool")
        #expect(
            composed.messages.last?.content == "[System Notice] Tool call budget: 1 of 2 remaining."
        )
        #expect(composed.messages.last?.tool_call_id == "call_1")
        // The only trailing non-tool-response user turn is still the genuine
        // query at index 1 — the template's last-query anchor is unmoved, so
        // the assistant tool-call turn keeps its cached reasoning rail.
        let userIndices = composed.messages.enumerated()
            .filter { $0.element.role == "user" }
            .map { $0.offset }
        #expect(userIndices == [1])
    }

    /// Multiple notices after a tool result all ride as tool feedback (none
    /// re-anchors the template's last user query).
    @Test func multipleTransientNoticesAfterToolResultAllRideAsToolFeedback() {
        let composed = AgentLoopBudget.appendingTransientNotices(
            ["[System Notice] a", "[System Notice] b"],
            to: [
                ChatMessage(role: "user", content: "q"),
                ChatMessage(
                    role: "tool",
                    content: "result",
                    tool_calls: nil,
                    tool_call_id: "call_9"
                ),
            ]
        )
        #expect(composed.count == 4)
        #expect(composed.suffix(2).allSatisfy { $0.role == "tool" })
        #expect(composed.suffix(2).allSatisfy { $0.tool_call_id == "call_9" })
        #expect(!composed.contains { $0.role == "user" && ($0.content ?? "").hasPrefix("[System Notice]") })
    }

    @Test func nativeImageEditContinuationNoticeAfterGenerateRidesAsUser() {
        let imageGenerateResult = ToolEnvelope.success(
            tool: "image",
            result: [
                "kind": "native_image_generation_job",
                "mode": "generate",
                "status": "completed",
                "images": [
                    [
                        "path": "/tmp/osaurus-images/generated-cube.png",
                        "url": "file:///tmp/osaurus-images/generated-cube.png",
                        "seed": 123,
                    ]
                ],
            ] as [String: Any]
        )
        let imageContinuation =
            "[System Notice] The previous `image` result saved image path(s): "
            + "`/tmp/osaurus-images/generated-cube.png`. Continue by calling `image` "
            + "with `source_paths` set to those path value(s)."
        let composed = AgentLoopBudget.appendingTransientNotices(
            [
                "[System Notice] Tool call budget: 1 of 2 remaining.",
                imageContinuation,
            ],
            to: [
                ChatMessage(role: "user", content: "generate then edit an image"),
                ChatMessage(
                    role: "tool",
                    content: imageGenerateResult,
                    tool_calls: nil,
                    tool_call_id: "call_image"
                ),
            ]
        )

        #expect(composed.count == 4)
        #expect(composed[2].role == "tool")
        #expect(composed[2].tool_call_id == "call_image")
        #expect(composed[2].content == "[System Notice] Tool call budget: 1 of 2 remaining.")
        #expect(composed[3].role == "user")
        #expect(composed[3].content == imageContinuation)
    }

    /// The empty-turn nudge (no preceding tool result) keeps the original
    /// trailing-user delivery — there is no cached tool-call rail to preserve.
    @Test func transientNoticeWithoutTrailingToolRidesAsUser() {
        let composed = AgentLoopBudget.appendingTransientNotices(
            ["[System Notice] previous turn produced no output"],
            to: [
                ChatMessage(role: "user", content: "hi"),
                ChatMessage(role: "assistant", content: ""),
            ]
        )
        #expect(composed.last?.role == "user")
        #expect(composed.last?.content == "[System Notice] previous turn produced no output")
    }

    @Test func foundationIdsResolveToFixedWindow() async {
        // The runtime resolver and the UI's sync twin must agree on the
        // Foundation ids — the historical bug had "default" resolving to
        // 4_096 in the UI and 128_000 in the runtime.
        for id in AgentLoopBudget.foundationModelIds {
            let runtime = await AgentLoopBudget.resolveContextWindow(modelId: id)
            #expect(runtime == AgentLoopBudget.foundationContextWindow)
            let ui = await MainActor.run {
                AgentLoopBudget.resolveContextWindowSync(modelId: id)
            }
            #expect(ui == runtime)
        }
    }
}
