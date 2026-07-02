//
//  EvalRunnerJudgeCalibration.swift
//  OsaurusEvalsKit
//
//  Runner for the `judge_calibration` domain: grade a FROZEN assistant
//  reply with the resolved judge and score the JUDGE against known
//  verdicts. Every rubric-graded domain (capability_claims, agent_loop,
//  default_agent, apple_script, screen_context) trusts the judge's
//  booleans; this is the lane that measures whether that trust is
//  earned — and makes "swap JUDGE_MODEL" a diffable change instead of
//  an invisible shift in every rubric grade.
//

import Foundation
import OsaurusCore

extension EvalRunner {

    /// Judge-calibration evaluator for `domain == "judge_calibration"`.
    /// Off-CI (one judge LLM call per case, no run-model loop). The run
    /// model is irrelevant to the grade except as the self-judge fallback
    /// when no strong judge resolves — a self-judged calibration run is
    /// itself useful (it measures the local model AS a judge) and the
    /// persisted audit + notes always name who graded.
    static func runJudgeCalibrationCase(
        _ testCase: EvalCase,
        modelId: String
    ) async -> EvalCaseReport {
        let label = testCase.label ?? testCase.id

        guard let exp = testCase.expect.judgeCalibration else {
            return Self.errored(
                testCase,
                label: label,
                modelId: modelId,
                note: "missing `expect.judgeCalibration`"
            )
        }
        guard exp.conditions.count == exp.expectedVerdicts.count, !exp.conditions.isEmpty else {
            return Self.errored(
                testCase,
                label: label,
                modelId: modelId,
                note: "conditions (\(exp.conditions.count)) and expectedVerdicts "
                    + "(\(exp.expectedVerdicts.count)) must be non-empty and equal-length"
            )
        }

        var notes: [String] = []
        var passed = true

        let judgeModel = EvalJudgeModel.resolveAndWarnOnce(runModelId: modelId)
        if judgeModel == nil {
            notes.append(
                "self-judge calibration: grading with the run model '\(modelId)' "
                    + "(no JUDGE_MODEL / strong *_API_KEY) — this row measures IT as a judge"
            )
        }
        await ensureJudgeProviderRoutable(judgeModel)

        let started = Date()
        let audit = await CapabilityClaimsEvaluator.judgeDetailed(
            finalText: exp.finalText,
            conditions: exp.conditions,
            model: judgeModel
        )
        let elapsed = Date().timeIntervalSince(started) * 1000
        let judgeAudit = EvalJudgeAudit.from(
            audit,
            rubric: exp.conditions,
            selfJudge: judgeModel == nil
        )

        // A thrown/unreachable judge is harness trouble, not a graded
        // mis-verdict — report it as errored so the matrix doesn't read an
        // outage as "the judge grades everything wrong".
        if audit.raw == nil {
            let reason = audit.verdicts.first?.reason ?? "no reply"
            return EvalCaseReport(
                id: testCase.id,
                label: label,
                domain: testCase.domain,
                query: testCase.query,
                outcome: .errored,
                notes: ["judge unreachable: \(reason)"],
                modelId: modelId,
                latencyMs: elapsed,
                judge: judgeAudit
            )
        }

        // Score the judge: one comparison per condition, index-aligned.
        for (index, expected) in exp.expectedVerdicts.enumerated() {
            let condition = exp.conditions[index]
            guard index < audit.verdicts.count else {
                passed = false
                notes.append("verdict \(index + 1) MISSING (expected \(expected)): \(condition)")
                continue
            }
            let verdict = audit.verdicts[index]
            if verdict.pass == expected {
                notes.append("verdict \(index + 1) ok (\(expected)): \(condition)")
            } else {
                passed = false
                notes.append(
                    "verdict \(index + 1) WRONG (judge said \(verdict.pass), expected \(expected)): "
                        + "\(condition) — judge reason: \(verdict.reason)"
                )
            }
        }
        if audit.verdicts.count > exp.expectedVerdicts.count {
            passed = false
            notes.append(
                "judge produced \(audit.verdicts.count) verdicts for "
                    + "\(exp.expectedVerdicts.count) conditions"
            )
        }
        notes.append("judge: \(audit.judgeModelId) (attempts=\(audit.attempts))")

        return EvalCaseReport(
            id: testCase.id,
            label: label,
            domain: testCase.domain,
            query: testCase.query,
            outcome: passed ? .passed : .failed,
            notes: notes,
            modelId: modelId,
            latencyMs: elapsed,
            // The judge call IS this domain's case work, so both fields
            // carry it: latencyMs for "what the case cost", judgeLatencyMs
            // for judge-time rollups across the whole report dir.
            judgeLatencyMs: elapsed,
            judge: judgeAudit
        )
    }
}
