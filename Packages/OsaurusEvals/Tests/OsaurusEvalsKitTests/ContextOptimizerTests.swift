import Foundation
import OsaurusCore
import Testing

@testable import OsaurusEvalsKit

/// Locks the optimizer's deterministic pieces: Pareto dominance rules
/// (directions, nil-objective conservatism), frontier selection (gate
/// failures never promotable; baseline competes), metrics extraction
/// from reports, artifact rendering, and profile-name slugging.
@Suite
struct ContextOptimizerTests {

    private func metrics(
        name: String,
        passed: Int = 8,
        scored: Int = 8,
        firstStep: Double? = nil,
        cumulative: Double? = nil,
        peak: Double? = nil,
        ttft: Double? = nil,
        tps: Double? = nil,
        ram: Double? = nil,
        gatePassed: Bool = true
    ) -> ParetoCandidateMetrics {
        ParetoCandidateMetrics(
            name: name,
            profileHash: nil,
            passed: passed,
            scored: scored,
            meanFirstStepTokens: firstStep,
            meanCumulativeTokens: cumulative,
            meanPeakContextTokens: peak,
            meanTtftMs: ttft,
            meanDecodeTps: tps,
            peakRamMb: ram,
            gatePassed: gatePassed,
            gateNotes: gatePassed ? [] : ["regression: x"]
        )
    }

    // MARK: - Dominance

    @Test func dominanceRespectsObjectiveDirections() {
        let cheaperSameQuality = metrics(name: "a", firstStep: 1000, tps: 20)
        let expensive = metrics(name: "b", firstStep: 2000, tps: 20)
        #expect(ParetoRanking.dominates(cheaperSameQuality, expensive))
        #expect(!ParetoRanking.dominates(expensive, cheaperSameQuality))

        // Trade-off (cheaper but slower) → neither dominates.
        let cheaperButSlower = metrics(name: "c", firstStep: 1000, tps: 10)
        let pricierButFaster = metrics(name: "d", firstStep: 2000, tps: 30)
        #expect(!ParetoRanking.dominates(cheaperButSlower, pricierButFaster))
        #expect(!ParetoRanking.dominates(pricierButFaster, cheaperButSlower))
    }

    @Test func dominanceSkipsUndefinedObjectives() {
        // b has no firstStep measurement — unknown must not read as worse,
        // so equality everywhere else means NO dominance either way.
        let a = metrics(name: "a", firstStep: 1000, tps: 20)
        let b = metrics(name: "b", tps: 20)
        #expect(!ParetoRanking.dominates(a, b))
        #expect(!ParetoRanking.dominates(b, a))
    }

    @Test func lowerPassRateNeverDominates() {
        let worseQualityCheaper = metrics(name: "a", passed: 6, scored: 8, firstStep: 500)
        let baselineQuality = metrics(name: "b", passed: 8, scored: 8, firstStep: 2000)
        #expect(!ParetoRanking.dominates(worseQualityCheaper, baselineQuality))
    }

    // MARK: - Frontier

    @Test func frontierExcludesGateFailuresAndDominatedRows() {
        let baseline = metrics(name: "baseline", firstStep: 3000)
        let winner = metrics(name: "combo-sections", firstStep: 1500)
        let dominated = metrics(name: "drop-one", firstStep: 2500)
        let gateFailed = metrics(name: "combo-all", firstStep: 800, gatePassed: false)
        let ranking = ParetoRanking(
            generatedAt: "2026-07-20T00:00:00Z",
            baseline: baseline,
            candidates: [winner, dominated, gateFailed]
        )
        // combo-all is the cheapest but regressed quality → never promotable.
        #expect(!ranking.frontier.contains("combo-all"))
        // drop-one is dominated by combo-sections (same quality, more tokens).
        #expect(ranking.frontier == ["combo-sections"])

        let md = ranking.formatMarkdown()
        #expect(md.contains("★ combo-sections"))
        #expect(md.contains("## Gate Failures"))
        #expect(md.contains("`combo-all`"))
    }

    @Test func frontierEmptyWhenBaselineDominatesEverything() {
        let baseline = metrics(name: "baseline", firstStep: 1000)
        let worse = metrics(name: "cand", firstStep: 2000)
        let ranking = ParetoRanking(
            generatedAt: "2026-07-20T00:00:00Z",
            baseline: baseline,
            candidates: [worse]
        )
        #expect(ranking.frontier.isEmpty)
    }

    // MARK: - Metrics extraction

    @Test func metricsExtractFromReportRows() {
        let ctx = ContextAttribution(
            sections: [], tools: [],
            systemPromptTokens: 0, toolSchemaTokens: 0, staticPrefixTokens: 0,
            firstStepInputTokens: 1200
        )
        let telemetry = EvalCaseTelemetry(
            decodeTokensPerSecond: 25,
            ttftMs: 900,
            promptTokensTotal: 5000,
            peakContextTokens: 3000,
            peakPhysFootprintMb: 9000
        )
        let report = EvalReport(
            modelId: "m",
            startedAt: "2026-07-20T00:00:00Z",
            cases: [
                EvalCaseReport(
                    id: "agent_loop.a", label: "a", domain: "agent_loop", query: nil,
                    outcome: .passed, notes: [], modelId: "m", latencyMs: 1,
                    telemetry: telemetry, context: ctx
                ),
                EvalCaseReport(
                    id: "agent_loop.b", label: "b", domain: "agent_loop", query: nil,
                    outcome: .failed, notes: [], modelId: "m", latencyMs: 1
                ),
                EvalCaseReport(
                    id: "agent_loop.c", label: "c", domain: "agent_loop", query: nil,
                    outcome: .skipped, notes: [], modelId: "m", latencyMs: nil
                ),
            ]
        )
        let m = ParetoCandidateMetrics.from(
            name: "x", report: report, gatePassed: true, gateNotes: []
        )
        #expect(m.passed == 1)
        #expect(m.scored == 2)  // skipped rows are not scored
        #expect(m.meanFirstStepTokens == 1200)
        #expect(m.meanCumulativeTokens == 5000)
        #expect(m.meanPeakContextTokens == 3000)
        #expect(m.peakRamMb == 9000)
    }

    // MARK: - Slug

    @Test func slugsAreProfileNameSafe() {
        #expect(ContextOptimizerSearch.slug("folderContext") == "foldercontext")
        #expect(ContextOptimizerSearch.slug("file_search") == "file-search")
        #expect(ContextOptimizerSearch.slug("weird  name!!") == "weird-name")
        // Slugged names must pass profile-name validation (no whitespace).
        let profile = ExperimentProfile(
            name: "drop-\(ContextOptimizerSearch.slug("agentLoopGuidance"))",
            dropSections: ["agentLoopGuidance"]
        )
        #expect(profile.validationErrors().isEmpty)
    }
}
