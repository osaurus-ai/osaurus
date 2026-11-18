//
//  EvalRunnerArchitectInline.swift
//  OsaurusEvalsKit
//
//  Runner for the `architect_inline` domain: one user message through
//  `architect_handoff` (`ArchitectInlineEvaluator`).
//  Live rows score the draft (time to its first step, step count), the run,
//  the keep offer, and promotion to an installed workflow. Rows that hold
//  the draft past a moved deadline score the hand back to the Orchestrator;
//  they make no model call and stay deterministic.
//

import Foundation
import OsaurusCore

extension EvalRunner {

    static func runArchitectInlineCase(_ testCase: EvalCase, modelId: String) async -> EvalCaseReport {
        let label = testCase.label ?? testCase.id
        guard let exp = testCase.expect.architectInline, !testCase.query.isEmpty else {
            return Self.errored(
                testCase, label: label, modelId: modelId, note: "missing `expect.architectInline` or `query`")
        }
        let deterministic = exp.holdDraft == true
        if scriptedOnly && !deterministic {
            return EvalCaseReport(
                id: testCase.id, label: label, domain: testCase.domain, query: testCase.query, outcome: .skipped,
                notes: ["SKIP: live row (OSAURUS_EVALS_SCRIPTED_ONLY=1)"], modelId: modelId, latencyMs: nil)
        }
        let options = ArchitectInlineEvaluator.Options(
            deadline: exp.deadline, holdDraft: deterministic,
            failSteps: exp.failSteps ?? false, stubStepText: exp.stubStepText, keep: exp.keep ?? false)
        // Hand-back rows never need the draft, so they name a model that does
        // not resolve: no load starts, and the row scores only the hand back.
        let outcome = await ArchitectInlineEvaluator.run(
            message: testCase.query, model: deterministic ? "eval/no-model" : modelId, options: options)

        var checks: [String] = []
        func check(_ ok: Bool, _ line: String) { checks.append((ok ? "PASS " : "FAIL ") + line) }

        check(outcome.result == exp.result, "result: expected \(exp.result), got \(outcome.result)")
        let wantOffer = exp.keepOffer ?? (exp.result == "completed")
        check(outcome.keepOffered == wantOffer, "keep offer: expected \(wantOffer), got \(outcome.keepOffered)")
        if exp.result == "completed" {
            check(outcome.ephemeral, "the draft ran as an ephemeral run")
            let limit = exp.maxFirstStepSeconds ?? outcome.firstStepBudgetSeconds ?? 10
            let first = outcome.firstStepSeconds.map { String(format: "%.2f", $0) } ?? "none"
            check(
                (outcome.firstStepSeconds ?? .infinity) <= limit,
                "first step running in \(first)s (limit \(String(format: "%.0f", limit))s)")
            let maxNodes = exp.maxNodes ?? 5
            check(
                outcome.nodeCount >= 1 && outcome.nodeCount <= maxNodes,
                "draft has \(outcome.nodeCount) step(s) (1…\(maxNodes))")
        }
        if let phase = exp.fallbackPhase {
            check(outcome.fallbackPhase == phase, "fallback phase \(outcome.fallbackPhase ?? "none") (want \(phase))")
        }
        if let options = exp.options {
            check(outcome.options == options, "options \(outcome.options) (want \(options))")
        }
        if exp.keep == true {
            check(outcome.savePrompted, "the yes raised the Save card")
            check(outcome.installedValid, "Save installed a valid workflow \(outcome.installedName.map { "\"\($0)\"" } ?? "")")
        }

        var notes = checks
        notes.append(
            "INFO total=\(String(format: "%.2f", outcome.totalSeconds))s nodes=\(outcome.nodeCount)"
                + (outcome.abandoned.map { " abandoned=\($0)" } ?? "")
                + (outcome.fallbackPhase.map { " fallback_phase=\($0)" } ?? "")
                + (outcome.draftBudgetSeconds.map { String(format: " draft_budget=%.0fs", $0) } ?? "")
                + (outcome.draftSeconds.map { String(format: " draft=%.2fs", $0) } ?? "")
                + (outcome.tokensPerSecond.map { String(format: " draft_tok/s=%.1f", $0) } ?? " draft_tok/s=none")
                + (outcome.completionTokens.map { " completion_tokens=\($0)" } ?? ""))
        if checks.contains(where: { $0.hasPrefix("FAIL") }) {
            notes.append("INFO envelope: \(String(outcome.envelope.prefix(600)))")
            if let draft = outcome.draftEnvelope {
                notes.append("INFO draft: \(String(draft.prefix(2000)))")
            }
            for (index, call) in outcome.draftCalls.enumerated() {
                notes.append("INFO draft call \(index + 1): \(String(call.prefix(3000)))")
            }
        }
        let passed = !checks.contains { $0.hasPrefix("FAIL") }
        return EvalCaseReport(
            id: testCase.id, label: label, domain: testCase.domain, query: testCase.query,
            outcome: passed ? .passed : .failed, notes: notes, modelId: modelId,
            latencyMs: outcome.totalSeconds * 1000,
            telemetry: EvalCaseTelemetry(
                decodeTokensPerSecond: outcome.tokensPerSecond,
                firstActionMs: outcome.firstStepSeconds.map { $0 * 1000 },
                completionTokens: outcome.completionTokens,
                promptTokensTotal: outcome.promptTokens))
    }
}
