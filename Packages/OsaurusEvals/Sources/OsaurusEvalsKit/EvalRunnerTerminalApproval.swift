//
//  EvalRunnerTerminalApproval.swift
//  OsaurusEvalsKit
//
//  Runner for the `terminal_approval` domain: deterministic, model-free pins
//  over how an external agent run's Ask cards are answered from the
//  `osaurus agent run` terminal. The scenarios live in
//  `TerminalApprovalEvalHarness` (OsaurusCore).
//

import Foundation
import OsaurusCore

extension EvalRunner {

    static func runTerminalApprovalCase(
        _ testCase: EvalCase,
        modelId: String
    ) async -> EvalCaseReport {
        let label = testCase.label ?? testCase.id
        guard let exp = testCase.expect.terminalApproval else {
            return Self.errored(
                testCase, label: label, modelId: modelId,
                note: "missing `expect.terminalApproval`"
            )
        }

        let started = Date()
        let outcome = await TerminalApprovalEvalHarness.run(scenario: exp.scenario)
        let elapsedMs = Date().timeIntervalSince(started) * 1000

        return EvalCaseReport(
            id: testCase.id,
            label: label,
            domain: testCase.domain,
            query: testCase.query,
            outcome: outcome.passed ? .passed : .failed,
            notes: ["scenario: \(exp.scenario)"] + outcome.checks,
            modelId: modelId,
            latencyMs: elapsedMs
        )
    }
}
