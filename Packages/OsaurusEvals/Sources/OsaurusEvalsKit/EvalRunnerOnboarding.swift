//
//  EvalRunnerOnboarding.swift
//  OsaurusEvalsKit
//
//  Runner for the `onboarding` domain: one deterministic check of the
//  first run through `OnboardingEvalHarness` in OsaurusCore. No model, so
//  the row is the same on every model it is run with.
//

import Foundation
import OsaurusCore

extension EvalRunner {

    static func runOnboardingCase(_ testCase: EvalCase, modelId: String) async -> EvalCaseReport {
        let label = testCase.label ?? testCase.id
        guard let exp = testCase.expect.onboarding else {
            return Self.errored(testCase, label: label, modelId: modelId, note: "missing `expect.onboarding`")
        }
        let started = Date()
        let outcome = await OnboardingEvalHarness.run(exp.check)
        return EvalCaseReport(
            id: testCase.id,
            label: label,
            domain: testCase.domain,
            query: testCase.query,
            outcome: outcome.passed ? .passed : .failed,
            notes: outcome.checks,
            modelId: modelId,
            latencyMs: Date().timeIntervalSince(started) * 1000
        )
    }
}
