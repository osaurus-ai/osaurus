//
//  StateCallScorecardTests.swift
//  OsaurusEvalsKitTests
//

import Foundation
import Testing

@testable import OsaurusEvalsKit

@Suite
struct StateCallScorecardTests {

    private static func row(
        model: String, calls: [String], source: String? = nil, outcome: EvalCaseOutcome = .passed,
        domain: String = "orchestrator"
    ) -> EvalCaseReport {
        EvalCaseReport(
            id: "orchestrator.\(model)-\(calls.joined(separator: "-"))", label: "", domain: domain,
            outcome: outcome,
            notes: ["mustCallTools ok: [state]", "summary: toolCalls=[\(calls.joined(separator: ","))] iters=2"]
                + (source.map { ["state_source: \($0)"] } ?? []),
            modelId: model, latencyMs: 1)
    }

    @Test func ratesEachModelOverHandledTurns() throws {
        let card = try #require(
            StateCallScorecard(
                rows: [
                    Self.row(model: "qwen", calls: ["configurator_handoff", "state"]),
                    Self.row(model: "qwen", calls: ["status"]),
                    Self.row(model: "qwen", calls: []),
                    Self.row(model: "qwen", calls: ["state"], outcome: .failed),
                    Self.row(model: "raptor", calls: ["state"]),
                ]))

        #expect(
            card.models == [
                .init(modelId: "qwen", withState: 2, written: 2, handled: 4),
                .init(modelId: "raptor", withState: 1, written: 1, handled: 1),
            ])
        let lines = card.formatLines()
        #expect(lines.first == "[state_call_rate] (orchestrator rows)")
        #expect(lines.contains("  qwen  calls 2/4 0.50  written 2/4 0.50  below 0.8"))
        #expect(lines.contains("  raptor  calls 1/1 1.00  written 1/1 1.00  ok"))
    }

    @Test func statesAsAWordInsideAnotherToolDoNotCount() throws {
        let card = try #require(
            StateCallScorecard(rows: [Self.row(model: "m", calls: ["state_dump"])]))
        #expect(card.models == [.init(modelId: "m", withState: 0, written: 0, handled: 1)])
    }

    @Test func extractedStateCountsAsWrittenButNotAsACall() throws {
        let card = try #require(
            StateCallScorecard(
                rows: [
                    Self.row(model: "m", calls: ["status"], source: "extracted"),
                    Self.row(model: "m", calls: ["state"], source: "model"),
                    Self.row(model: "m", calls: [], source: "none"),
                    // A `state` call that failed, then extraction: one write.
                    Self.row(model: "m", calls: ["state"], source: "extracted"),
                ]))
        #expect(card.models == [.init(modelId: "m", withState: 2, written: 3, handled: 4)])
        #expect(card.formatLines().contains("  m  calls 2/4 0.50  written 3/4 0.75  below 0.8"))
    }

    @Test func erroredAndOtherDomainRowsAreIgnored() {
        let errored = Self.row(model: "m", calls: ["state"], outcome: .errored)
        let other = Self.row(model: "m", calls: ["state"], domain: "onboarding")
        #expect(StateCallScorecard(rows: [errored, other]) == nil)
    }
}
