import Foundation
import OsaurusCore
import Testing

@testable import OsaurusEvalsKit

/// Locks the STRICT promotion rules for the context-optimization
/// harness: pass→fail always blocks (no flake amnesty), new
/// errors/skips block, lower per-case pass rates on repeat-trial rows
/// block, catalog drift blocks, a failing judge-calibration lane
/// blocks, and the hard first-step context budget blocks when exceeded.
@Suite
struct PromotionGateTests {

    private func row(
        id: String,
        domain: String = "agent_loop",
        outcome: EvalCaseOutcome = .passed,
        trials: Int? = nil,
        trialsPassed: Int? = nil,
        firstStep: Int? = nil
    ) -> EvalCaseReport {
        let context = firstStep.map { first in
            ContextAttribution(
                sections: [.init(id: "platform", label: "platform", tokens: first, cacheability: "static")],
                tools: [],
                systemPromptTokens: first,
                toolSchemaTokens: 0,
                staticPrefixTokens: first,
                firstStepInputTokens: first
            )
        }
        return EvalCaseReport(
            id: id, label: id, domain: domain, query: nil,
            outcome: outcome, notes: [], modelId: "m", latencyMs: 10,
            trials: trials, trialsPassed: trialsPassed,
            context: context
        )
    }

    private func report(_ cases: [EvalCaseReport], judge: String? = nil) -> EvalReport {
        EvalReport(
            modelId: "m",
            startedAt: "2026-07-20T00:00:00Z",
            cases: cases,
            environment: judge.map {
                RunEnvironment(judge: $0)
            }
        )
    }

    @Test func identicalRunsArePromotable() {
        let rows = [row(id: "a"), row(id: "b")]
        let verdict = PromotionGate.evaluate(
            baseline: report(rows), candidate: report(rows)
        )
        #expect(verdict.promotable)
        #expect(verdict.blocking.isEmpty)
    }

    @Test func passToFailBlocksEvenWhenFlaky() {
        let verdict = PromotionGate.evaluate(
            baseline: report([row(id: "a", trials: 5, trialsPassed: 5)]),
            candidate: report([row(id: "a", outcome: .failed, trials: 5, trialsPassed: 3)])
        )
        #expect(!verdict.promotable)
        #expect(verdict.blocking.contains { $0.contains("pass → failed") })
        // Flake evidence is surfaced but never downgrades the block.
        #expect(verdict.blocking.contains { $0.contains("rerun with more trials") })
    }

    @Test func newSkipAndNewErrorBlock() {
        let verdict = PromotionGate.evaluate(
            baseline: report([row(id: "a", outcome: .failed), row(id: "b", outcome: .failed)]),
            candidate: report([row(id: "a", outcome: .skipped), row(id: "b", outcome: .errored)])
        )
        #expect(!verdict.promotable)
        #expect(verdict.blocking.contains { $0.contains("new skip") })
        #expect(verdict.blocking.contains { $0.contains("new error") })
    }

    @Test func lowerPassRateOnStillPassingRowBlocks() {
        let verdict = PromotionGate.evaluate(
            baseline: report([row(id: "a", trials: 5, trialsPassed: 5)]),
            candidate: report([row(id: "a", trials: 5, trialsPassed: 4)])
        )
        #expect(!verdict.promotable)
        #expect(verdict.blocking.contains { $0.contains("pass rate dropped 5/5 → 4/5") })
    }

    @Test func improvedPassRateIsAdvisoryOnly() {
        let verdict = PromotionGate.evaluate(
            baseline: report([row(id: "a", outcome: .failed, trials: 5, trialsPassed: 2)]),
            candidate: report([row(id: "a", outcome: .failed, trials: 5, trialsPassed: 4)])
        )
        #expect(verdict.promotable)
        #expect(verdict.advisories.contains { $0.contains("improved") })
    }

    @Test func catalogDriftBlocksBothDirections() {
        let verdict = PromotionGate.evaluate(
            baseline: report([row(id: "a"), row(id: "b")]),
            candidate: report([row(id: "a"), row(id: "c")])
        )
        #expect(!verdict.promotable)
        #expect(verdict.blocking.contains { $0.contains("missing 1 baseline case") })
        #expect(verdict.blocking.contains { $0.contains("adds 1 case") })
    }

    @Test func failingJudgeCalibrationLaneBlocks() {
        let verdict = PromotionGate.evaluate(
            baseline: report([
                row(id: "a"), row(id: "judge.cal", domain: "judge_calibration"),
            ]),
            candidate: report([
                row(id: "a"),
                row(id: "judge.cal", domain: "judge_calibration", outcome: .failed),
            ])
        )
        #expect(!verdict.promotable)
        #expect(verdict.blocking.contains { $0.contains("judge calibration failing") })
    }

    @Test func contextBudgetGatesMeanFirstStep() {
        let over = PromotionGate.evaluate(
            baseline: report([row(id: "a", firstStep: 900)]),
            candidate: report([row(id: "a", firstStep: 1200)]),
            maxFirstStepContextTokens: 1000
        )
        #expect(!over.promotable)
        #expect(over.blocking.contains { $0.contains("context budget exceeded") })

        let under = PromotionGate.evaluate(
            baseline: report([row(id: "a", firstStep: 900)]),
            candidate: report([row(id: "a", firstStep: 800)]),
            maxFirstStepContextTokens: 1000
        )
        #expect(under.promotable)
        #expect(under.advisories.contains { $0.contains("context budget ok") })
    }

    @Test func missingAttributionUnderBudgetIsAdvisoryNotBlock() {
        let verdict = PromotionGate.evaluate(
            baseline: report([row(id: "a")]),
            candidate: report([row(id: "a")]),
            maxFirstStepContextTokens: 1000
        )
        #expect(verdict.promotable)
        #expect(verdict.advisories.contains { $0.contains("no candidate row carried") })
    }

    @Test func judgeMismatchIsAdvisory() {
        let verdict = PromotionGate.evaluate(
            baseline: report([row(id: "a")], judge: "xai/grok-4.3"),
            candidate: report([row(id: "a")], judge: "self-judge")
        )
        #expect(verdict.promotable)
        #expect(verdict.advisories.contains { $0.contains("judge differs") })
    }
}
