import Foundation
import OsaurusCore
import Testing

@testable import OsaurusEvalsKit

/// Locks the context-attribution reporting contract for the optimization
/// harness: per-row "where do the tokens go" lines render for PASSING rows,
/// attribution survives JSON round-trips and trial merging, the matrix
/// rolls up mean first-step cost + top contributors, and the diff computes
/// per-contributor movers with dropped contributors counted from zero.
@Suite
struct ContextAttributionReportTests {

    private func attribution(
        sections: [(String, Int)],
        tools: [(String, Int)] = [],
        firstStep: Int? = nil
    ) -> ContextAttribution {
        let sectionCosts = sections.map {
            ContextAttribution.SectionCost(
                id: $0.0, label: $0.0, tokens: $0.1, cacheability: "static"
            )
        }
        let toolCosts = tools.map { ContextAttribution.ToolCost(name: $0.0, tokens: $0.1) }
        return ContextAttribution(
            sections: sectionCosts,
            tools: toolCosts,
            systemPromptTokens: sections.reduce(0) { $0 + $1.1 },
            toolSchemaTokens: tools.reduce(0) { $0 + $1.1 },
            staticPrefixTokens: sections.reduce(0) { $0 + $1.1 },
            firstStepInputTokens: firstStep
        )
    }

    private func caseReport(
        id: String,
        outcome: EvalCaseOutcome = .passed,
        context: ContextAttribution?
    ) -> EvalCaseReport {
        EvalCaseReport(
            id: id, label: id, domain: "agent_loop", query: nil,
            outcome: outcome, notes: [], modelId: "m", latencyMs: 10,
            context: context
        )
    }

    // MARK: - topContributors

    @Test func topContributorsMixSectionsAndToolsLargestFirst() {
        let a = attribution(
            sections: [("platform", 100), ("sandbox", 900)],
            tools: [("web_search", 500), ("todo", 40)]
        )
        let top = a.topContributors(3)
        #expect(top.map(\.name) == ["§sandbox", "tool:web_search", "§platform"])
        #expect(top.map(\.tokens) == [900, 500, 100])
    }

    // MARK: - Report rendering + persistence

    @Test func passingRowRendersContextLineAndSuiteRollup() {
        let report = EvalReport(
            modelId: "m",
            startedAt: "2026-07-20T00:00:00Z",
            cases: [
                caseReport(
                    id: "agent_loop.a",
                    context: attribution(
                        sections: [("platform", 100)], tools: [("todo", 50)], firstStep: 150
                    )
                )
            ]
        )
        let text = report.formatHumanReadable()
        // Attribution must surface on a PASSED row (the whole point).
        #expect(text.contains("ctx-attr: prompt 100"))
        #expect(text.contains("first-step 150"))
        #expect(text.contains("[context attribution]"))
        #expect(text.contains("first-step tok  mean=150"))
    }

    @Test func contextSurvivesJSONRoundTrip() throws {
        let report = EvalReport(
            modelId: "m",
            startedAt: "2026-07-20T00:00:00Z",
            cases: [
                caseReport(
                    id: "agent_loop.a",
                    context: attribution(sections: [("platform", 100)], firstStep: 120)
                )
            ]
        )
        let decoded = try JSONDecoder().decode(EvalReport.self, from: report.toJSON())
        #expect(decoded.cases[0].context == report.cases[0].context)
        #expect(decoded.cases[0].context?.firstStepInputTokens == 120)
    }

    @Test @MainActor func resourceTelemetryMergePreservesAttribution() {
        // Regression: the runner's resource-sampling wrapper rebuilds the
        // row to fold in RAM/CPU/KV telemetry; the rebuild MUST carry the
        // context block (it silently dropped it once, which nil'd
        // attribution for every agent_loop row).
        let ctx = attribution(sections: [("platform", 100)], firstStep: 140)
        let merged = EvalRunner.mergeResourceTelemetry(
            into: caseReport(id: "agent_loop.a", context: ctx),
            sample: ResourceSample(peakPhysFootprintMb: 1024, meanCpuPercent: 10, peakCpuPercent: 20),
            kvBefore: nil,
            kvAfter: nil
        )
        #expect(merged.context == ctx)
        #expect(merged.telemetry?.peakPhysFootprintMb == 1024)
    }

    @Test func mergedTrialsKeepAttribution() {
        let ctx = attribution(sections: [("platform", 100)], firstStep: 130)
        let trials = [
            caseReport(id: "agent_loop.a", outcome: .passed, context: ctx),
            caseReport(id: "agent_loop.a", outcome: .failed, context: ctx),
        ]
        let merged = EvalCaseReport.mergedTrials(trials)
        #expect(merged.trials == 2)
        #expect(merged.context == ctx)
    }

    // MARK: - Matrix rollup

    @Test func matrixRollsUpFirstStepMeanAndTopContributors() {
        let cases = [
            caseReport(
                id: "agent_loop.a",
                context: attribution(
                    sections: [("platform", 100), ("sandbox", 800)],
                    tools: [("web_search", 400)],
                    firstStep: 1000
                )
            ),
            caseReport(
                id: "agent_loop.b",
                context: attribution(
                    sections: [("platform", 100), ("sandbox", 600)],
                    tools: [("web_search", 400)],
                    firstStep: 2000
                )
            ),
        ]
        let col = EvalMatrixBuilder.build(from: [
            EvalReport(modelId: "m", startedAt: "2026-07-20T00:00:00Z", cases: cases)
        ]).models[0]
        #expect(col.meanFirstStepContextTokens == 1500)
        // sandbox mean=700 > web_search mean=400 > platform mean=100.
        #expect(col.topContextContributors?.first == "§sandbox=700")
        #expect(col.topContextContributors?.contains("tool:web_search=400") == true)

        let md = EvalMatrix(
            generatedAt: "2026-07-20T00:00:00Z", domains: ["agent_loop"], models: [col]
        ).formatMarkdown()
        #expect(md.contains("first-step ctx tok (mean)"))
        #expect(md.contains("## Top Context Contributors"))
    }

    @Test func matrixWithoutAttributionStaysNil() {
        let col = EvalMatrixBuilder.build(from: [
            EvalReport(
                modelId: "m",
                startedAt: "2026-07-20T00:00:00Z",
                cases: [caseReport(id: "agent_loop.a", context: nil)]
            )
        ]).models[0]
        #expect(col.meanFirstStepContextTokens == nil)
        #expect(col.topContextContributors == nil)
    }

    // MARK: - Diff movers

    @Test func contextMoversRankByAbsoluteDeltaAndCountDropsFromZero() {
        let base = attribution(
            sections: [("platform", 100), ("sandbox", 800)],
            tools: [("web_search", 400)]
        )
        let current = attribution(
            sections: [("platform", 100)],  // sandbox dropped entirely
            tools: [("web_search", 250), ("todo", 40)]  // shrunk + added
        )
        let movers = EvalDiff.contextMovers(baseline: base, current: current)
        #expect(movers == ["§sandbox -800", "tool:web_search -150", "tool:todo +40"])
    }

    @Test func contextMoversNilWithoutAttributionOrMovement() {
        #expect(EvalDiff.contextMovers(baseline: nil, current: nil) == nil)
        let same = attribution(sections: [("platform", 100)])
        #expect(EvalDiff.contextMovers(baseline: same, current: same) == nil)
    }
}
