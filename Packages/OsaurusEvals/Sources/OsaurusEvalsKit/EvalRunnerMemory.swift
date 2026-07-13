//
//  EvalRunnerMemory.swift
//  OsaurusEvalsKit
//
//  Runner for the `memory` domain. Seeds the ISOLATED memory store (the
//  eval bootstrap points OsaurusPaths at a temp root) from
//  `fixtures.seedMemory`, runs a multi-turn chat through
//  `MemoryRecallEvaluator` — the production relevance-gate → planner →
//  inject path — and scores recall in the visible answers.
//
//  Case-authoring contract: the recall needle should be a fixture-unique
//  codeword (e.g. "the project codename is ZIRCON-42") so a pass can only
//  come from the injected memory, never from a lucky generic answer.
//  Each case runs under its own random agent id, so per-agent seeds can't
//  bleed between cases; global identity overrides are wiped after each
//  case by `MemoryRecallEvaluator.reset()`.
//

import Foundation
import OsaurusCore

extension EvalRunner {

    static func runMemoryCase(
        _ testCase: EvalCase,
        modelId: String
    ) async -> EvalCaseReport {
        let label = testCase.label ?? testCase.id
        guard let exp = testCase.expect.memory else {
            return Self.errored(
                testCase, label: label, modelId: modelId,
                note: "missing `expect.memory`"
            )
        }
        guard let seeds = testCase.fixtures.seedMemory else {
            return Self.errored(
                testCase, label: label, modelId: modelId,
                note: "memory case missing `fixtures.seedMemory` — nothing to recall"
            )
        }

        // Unique per-case agent id: per-agent seed rows are isolated by
        // construction, so cases stay order-independent.
        let agentId = UUID().uuidString

        do {
            try MemoryRecallEvaluator.seed(
                agentId: agentId,
                pinnedFacts: seeds.pinnedFacts ?? [],
                episodes: (seeds.episodes ?? []).map {
                    MemoryRecallEvaluator.EpisodeSeedInput(
                        summary: $0.summary,
                        topicsCSV: $0.topics ?? "",
                        entitiesCSV: $0.entities ?? ""
                    )
                },
                identityOverrides: seeds.identityOverrides ?? []
            )
        } catch {
            return Self.errored(
                testCase, label: label, modelId: modelId,
                note: "memory seeding failed: \(error.localizedDescription)"
            )
        }

        let queries = [testCase.query] + (exp.followUpTurns ?? [])
        let started = Date()
        let transcript = await MemoryRecallEvaluator.run(
            queries: queries,
            agentId: agentId,
            maxTokens: exp.maxTokens ?? 512
        )
        let elapsedMs = Date().timeIntervalSince(started) * 1000
        await MemoryRecallEvaluator.reset()

        if let err = transcript.error {
            return EvalCaseReport(
                id: testCase.id,
                label: label,
                domain: testCase.domain,
                query: testCase.query,
                outcome: .errored,
                notes: [
                    "memory run failed: \(err)",
                    "completed turns: \(transcript.turns.count)/\(queries.count)",
                ],
                modelId: modelId,
                latencyMs: elapsedMs
            )
        }

        var notes: [String] = [
            "turns: \(transcript.turns.count) · memory injected on: "
                + transcript.turns.enumerated()
                .filter { $0.element.memoryInjected }
                .map { String($0.offset + 1) }
                .joined(separator: ",")
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

        if exp.requireMemoryInjected ?? false {
            check(
                transcript.turns.first?.memoryInjected == true,
                pass: "memory section injected on turn 1",
                fail: "memory section NOT injected on turn 1 (gate declined or store empty)"
            )
        }

        if let needles = exp.answerContains, let finalTurn = transcript.turns.last {
            let haystack = finalTurn.visibleText.lowercased()
            for needle in needles {
                check(
                    haystack.contains(needle.lowercased()),
                    pass: "final answer contains '\(needle)'",
                    fail: "final answer missing '\(needle)' — memory not recalled"
                )
            }
        }
        if let banned = exp.answerMustNotContain {
            for (index, turn) in transcript.turns.enumerated() {
                let haystack = turn.visibleText.lowercased()
                let hits = banned.filter { haystack.contains($0.lowercased()) }
                check(
                    hits.isEmpty,
                    pass: "turn \(index + 1): no banned substrings",
                    fail: "turn \(index + 1): surfaced banned substring(s) \(hits)"
                )
            }
        }

        return EvalCaseReport(
            id: testCase.id,
            label: label,
            domain: testCase.domain,
            query: testCase.query,
            outcome: passed ? .passed : .failed,
            notes: notes,
            modelId: modelId,
            latencyMs: elapsedMs
        )
    }
}
