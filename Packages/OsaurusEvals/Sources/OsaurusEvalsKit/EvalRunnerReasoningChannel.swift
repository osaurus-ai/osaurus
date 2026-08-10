//
//  EvalRunnerReasoningChannel.swift
//  OsaurusEvalsKit
//
//  Runner for the `reasoning_channel` domain — the scoreable form of the
//  AGENTS.md reasoning non-negotiables. Drives tool-free chat turns
//  through `ReasoningChannelEvaluator` (the real ChatEngine streaming
//  path) and asserts, deterministically:
//    - raw parser markers never leak into visible text (built-in marker
//      list + per-case extras);
//    - the runtime never reports an unclosed reasoning span;
//    - every turn produces a visible answer (no reasoning-only output);
//    - reasoning lands on the structured channel when the case pins it;
//    - later turns never verbatim-echo an earlier turn's reasoning.
//
//  Cases whose assertions REQUIRE a reasoning channel SKIP (not fail) on
//  models with no channel, so the same suite runs honestly on
//  foundation/instruct-only hosts.
//

import Foundation
import OsaurusCore

extension EvalRunner {

    /// Family-agnostic raw markers that must never appear on the visible
    /// channel, whatever model family is routed. Kept small and exact —
    /// these are protocol tokens, not vocabulary.
    static let builtInForbiddenVisibleMarkers: [String] = [
        "<think>", "</think>",
        "<thinking>", "</thinking>",
        "<|im_start|>", "<|im_end|>",
        "<|channel|>", "<|message|>", "<|end|>",
        "<seed:think>", "</seed:think>",
        "<|thinking|>", "<|/thinking|>",
        "[THINK]", "[/THINK]",
        "◁think▷", "◁/think▷",
        "<tool_call>", "</tool_call>",
        "<|tool_calls_section_begin|>", "<|tool_call_begin|>",
        "<|dsml|>", "</|dsml|>",
    ]

    static func runReasoningChannelCase(
        _ testCase: EvalCase,
        modelId: String
    ) async -> EvalCaseReport {
        let label = testCase.label ?? testCase.id
        guard let exp = testCase.expect.reasoning else {
            return Self.errored(
                testCase, label: label, modelId: modelId,
                note: "missing `expect.reasoning`"
            )
        }

        let queries = [testCase.query] + (exp.followUpTurns ?? [])
        let started = Date()
        let transcript = await ReasoningChannelEvaluator.run(
            queries: queries,
            maxTokens: exp.maxTokens ?? 1_024
        )
        let elapsedMs = Date().timeIntervalSince(started) * 1000

        // reasoningFieldExpected == "yes" is the one assertion that cannot
        // be scored on a channel-less model — SKIP with the exact reason.
        let fieldExpectation = (exp.reasoningFieldExpected ?? "either").lowercased()
        if fieldExpectation == "yes", !transcript.modelSupportsThinking {
            return .terminal(
                id: testCase.id,
                label: label,
                domain: testCase.domain,
                outcome: .skipped,
                notes: [
                    "SKIP: case requires a reasoning channel but the resolved model "
                        + "has none (LocalReasoningCapability detection)"
                ],
                modelId: modelId
            )
        }

        if let err = transcript.error {
            return EvalCaseReport(
                id: testCase.id,
                label: label,
                domain: testCase.domain,
                query: testCase.query,
                outcome: .errored,
                notes: [
                    "reasoning-channel run failed: \(err)",
                    "completed turns: \(transcript.turns.count)/\(queries.count)",
                ],
                modelId: modelId,
                latencyMs: elapsedMs
            )
        }

        var notes: [String] = [
            "turns: \(transcript.turns.count) · model reasoning channel: "
                + (transcript.modelSupportsThinking ? "yes" : "no")
        ]
        var passed = true
        func check(_ ok: Bool, pass: String, fail: String) {
            if ok {
                notes.append("ok: \(pass)")
            } else {
                passed = false
                notes.append("FAIL: \(fail)")
            }
        }

        let forbidden = builtInForbiddenVisibleMarkers + (exp.forbiddenVisibleMarkers ?? [])
        let requireVisible = exp.requireVisibleAnswer ?? true

        for (index, turn) in transcript.turns.enumerated() {
            let turnNo = index + 1
            let visible = turn.visibleText

            // Marker-leak sweep: the heart of the domain.
            let leaked = forbidden.filter { visible.contains($0) }
            check(
                leaked.isEmpty,
                pass: "turn \(turnNo): no raw parser markers in visible text",
                fail: "turn \(turnNo): visible text leaked marker(s) \(leaked)"
            )

            check(
                !turn.unclosedReasoning,
                pass: "turn \(turnNo): reasoning span closed",
                fail: "turn \(turnNo): runtime reported an UNCLOSED reasoning span"
            )

            if requireVisible {
                check(
                    !visible.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                    pass: "turn \(turnNo): visible answer non-empty",
                    fail: "turn \(turnNo): NO visible answer (reasoning-only or empty output)"
                )
            }

            // Cross-turn reasoning echo: a later turn's visible text must
            // not verbatim-reproduce an earlier turn's private reasoning.
            for earlier in 0 ..< index {
                let earlierReasoning = transcript.turns[earlier].reasoningText
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                // Substantial spans only: short common words would false-positive.
                guard earlierReasoning.count >= 48 else { continue }
                check(
                    !visible.contains(earlierReasoning),
                    pass: "turn \(turnNo): does not echo turn \(earlier + 1) reasoning",
                    fail: "turn \(turnNo): visible text ECHOES turn \(earlier + 1)'s reasoning verbatim"
                )
            }
        }

        switch fieldExpectation {
        case "yes":
            let anyReasoning = transcript.turns.contains {
                !$0.reasoningText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
            check(
                anyReasoning,
                pass: "reasoning landed on the structured channel",
                fail: "model advertises a reasoning channel but the structured field stayed empty"
            )
        case "no":
            let stray = transcript.turns.enumerated().filter {
                !$0.element.reasoningText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
            check(
                stray.isEmpty,
                pass: "reasoning field empty on every turn (as pinned)",
                fail: "reasoning field unexpectedly non-empty on turn(s) "
                    + stray.map { String($0.offset + 1) }.joined(separator: ",")
            )
        default:
            break
        }

        if let needles = exp.visibleContains, let finalTurn = transcript.turns.last {
            let haystack = finalTurn.visibleText.lowercased()
            for needle in needles {
                check(
                    haystack.contains(needle.lowercased()),
                    pass: "final answer contains '\(needle)'",
                    fail: "final answer missing '\(needle)'"
                )
            }
        }
        if let banned = exp.visibleMustNotContain {
            for (index, turn) in transcript.turns.enumerated() {
                let haystack = turn.visibleText.lowercased()
                let hits = banned.filter { haystack.contains($0.lowercased()) }
                check(
                    hits.isEmpty,
                    pass: "turn \(index + 1): no banned substrings",
                    fail: "turn \(index + 1): contains banned substring(s) \(hits)"
                )
            }
        }

        // Every generation row carries token/s when the runtime reported it.
        let tpsValues = transcript.turns.compactMap(\.decodeTokensPerSecond)
        if let last = tpsValues.last {
            notes.append(String(format: "decode tok/s (last turn): %.1f", last))
        }

        return EvalCaseReport(
            id: testCase.id,
            label: label,
            domain: testCase.domain,
            query: testCase.query,
            outcome: passed ? .passed : .failed,
            notes: notes,
            modelId: modelId,
            latencyMs: elapsedMs,
            telemetry: EvalCaseTelemetry(
                decodeTokensPerSecond: tpsValues.last,
                completionTokens: {
                    let counts = transcript.turns.compactMap(\.tokenCount)
                    return counts.isEmpty ? nil : counts.reduce(0, +)
                }()
            )
        )
    }
}
