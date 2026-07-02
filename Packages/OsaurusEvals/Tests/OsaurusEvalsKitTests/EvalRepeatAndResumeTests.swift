import Foundation
import Testing

@testable import OsaurusEvalsKit

/// Locks the statistical-rigor layer: `--repeat` trial merging
/// (`EvalCaseReport.mergedTrials`), the flake-aware diff classification
/// (a pass→fail flip with trial disagreement is "suspected flaky", not a
/// blocking regression), and the `--resume` completed-row filter.
@Suite
struct EvalRepeatAndResumeTests {

    private func row(
        id: String = "case.a",
        outcome: EvalCaseOutcome,
        notes: [String] = [],
        latencyMs: Double? = 100,
        trials: Int? = nil,
        trialsPassed: Int? = nil
    ) -> EvalCaseReport {
        EvalCaseReport(
            id: id,
            label: id,
            domain: "agent_loop",
            outcome: outcome,
            notes: notes,
            modelId: "m",
            latencyMs: latencyMs,
            trials: trials,
            trialsPassed: trialsPassed
        )
    }

    // MARK: - mergedTrials

    @Test func singleTrialReturnsRowUnchanged() {
        let merged = EvalCaseReport.mergedTrials([row(outcome: .failed, notes: ["boom"])])
        #expect(merged.outcome == .failed)
        #expect(merged.trials == nil)
        #expect(merged.trialsPassed == nil)
        #expect(merged.notes == ["boom"])
    }

    @Test func majorityPassWins() {
        let merged = EvalCaseReport.mergedTrials([
            row(outcome: .passed), row(outcome: .failed), row(outcome: .passed),
        ])
        #expect(merged.outcome == .passed)
        #expect(merged.trials == 3)
        #expect(merged.trialsPassed == 2)
        #expect(merged.isFlaky)
        #expect(merged.passRate == 2.0 / 3.0)
        #expect(merged.notes.contains { $0.contains("FLAKY") })
        #expect(merged.notes.contains { $0.contains("trial 2: failed") })
    }

    @Test func tieIsConservativeFail() {
        let merged = EvalCaseReport.mergedTrials([row(outcome: .passed), row(outcome: .failed)])
        #expect(merged.outcome == .failed)
        #expect(merged.trials == 2)
        #expect(merged.trialsPassed == 1)
        #expect(merged.isFlaky)
    }

    @Test func allErroredStaysErrored() {
        let merged = EvalCaseReport.mergedTrials([
            row(outcome: .errored, notes: ["hang"]), row(outcome: .errored, notes: ["hang"]),
        ])
        #expect(merged.outcome == .errored)
        #expect(merged.trialsPassed == 0)
        #expect(!merged.isFlaky)
    }

    @Test func mixedFailErrorIsFailed() {
        let merged = EvalCaseReport.mergedTrials([
            row(outcome: .failed), row(outcome: .errored), row(outcome: .failed),
        ])
        #expect(merged.outcome == .failed)
        #expect(merged.trialsPassed == 0)
    }

    @Test func allPassedIsCleanPass() {
        let merged = EvalCaseReport.mergedTrials([
            row(outcome: .passed), row(outcome: .passed),
        ])
        #expect(merged.outcome == .passed)
        #expect(merged.trials == 2)
        #expect(merged.trialsPassed == 2)
        #expect(!merged.isFlaky)
        // Clean agreement: no per-trial outcome map, just the summary.
        #expect(merged.notes.first == "trials: 2/2 passed")
    }

    @Test func meanLatencyAcrossTrials() {
        let merged = EvalCaseReport.mergedTrials([
            row(outcome: .passed, latencyMs: 100), row(outcome: .passed, latencyMs: 300),
        ])
        #expect(merged.latencyMs == 200)
    }

    @Test func skippedFirstTrialStaysSkipped() {
        let merged = EvalCaseReport.mergedTrials([row(outcome: .skipped, notes: ["missing plugin"])])
        #expect(merged.outcome == .skipped)
        #expect(merged.notes == ["missing plugin"])
    }

    // MARK: - flake-aware diff

    private func reportSet(label: String, rows: [EvalCaseReport]) -> AgentLoopRegressionReportSet {
        AgentLoopRegressionReportSet(
            label: label,
            reports: [
                .init(
                    name: "suite",
                    url: nil,
                    report: EvalReport(modelId: "m", startedAt: "2026-06-19T00:00:00Z", cases: rows)
                )
            ]
        )
    }

    @Test func hardFlipWithoutTrialsBlocks() {
        let summary = EvalDiff.compare(
            baseline: reportSet(label: "base", rows: [row(outcome: .passed)]),
            current: reportSet(label: "cur", rows: [row(outcome: .failed)])
        )
        #expect(summary.regressions.count == 1)
        #expect(summary.suspectedFlaky.isEmpty)
        #expect(summary.hasBlockingRegressions)
    }

    @Test func flipWithFlakyCurrentTrialsIsSuspectedFlaky() {
        let summary = EvalDiff.compare(
            baseline: reportSet(label: "base", rows: [row(outcome: .passed)]),
            current: reportSet(
                label: "cur",
                rows: [row(outcome: .failed, trials: 3, trialsPassed: 1)]
            )
        )
        #expect(summary.regressions.isEmpty)
        #expect(summary.suspectedFlaky.count == 1)
        #expect(!summary.hasBlockingRegressions)
        #expect(summary.formatConsole().contains("suspected flaky"))
        #expect(summary.formatMarkdown().contains("Suspected Flaky"))
    }

    @Test func flipWithFlakyBaselineTrialsIsSuspectedFlaky() {
        let summary = EvalDiff.compare(
            baseline: reportSet(
                label: "base",
                rows: [row(outcome: .passed, trials: 3, trialsPassed: 2)]
            ),
            current: reportSet(label: "cur", rows: [row(outcome: .failed)])
        )
        #expect(summary.regressions.isEmpty)
        #expect(summary.suspectedFlaky.count == 1)
    }

    @Test func unanimousFailAcrossTrialsStaysBlocking() {
        let summary = EvalDiff.compare(
            baseline: reportSet(label: "base", rows: [row(outcome: .passed, trials: 3, trialsPassed: 3)]),
            current: reportSet(label: "cur", rows: [row(outcome: .failed, trials: 3, trialsPassed: 0)])
        )
        #expect(summary.regressions.count == 1)
        #expect(summary.suspectedFlaky.isEmpty)
        #expect(summary.hasBlockingRegressions)
    }

    // MARK: - matrix flake rollup

    @Test func matrixCountsFlakyCases() {
        let report = EvalReport(
            modelId: "m",
            startedAt: "2026-06-19T00:00:00Z",
            cases: [
                row(id: "a", outcome: .passed, trials: 3, trialsPassed: 3),
                row(id: "b", outcome: .passed, trials: 3, trialsPassed: 2),
                row(id: "c", outcome: .failed, trials: 3, trialsPassed: 1),
            ]
        )
        let matrix = EvalMatrixBuilder.build(from: [report])
        #expect(matrix.models.count == 1)
        #expect(matrix.models[0].flakyCases == 2)

        let noTrials = EvalMatrixBuilder.build(from: [
            EvalReport(
                modelId: "m",
                startedAt: "2026-06-19T00:00:00Z",
                cases: [row(id: "a", outcome: .passed)]
            )
        ])
        #expect(noTrials.models[0].flakyCases == nil)
    }

    // MARK: - resume filtering

    @Test func completedRowsDropErroredAndBlocked() {
        let rows = [
            row(id: "a", outcome: .passed),
            row(id: "b", outcome: .failed),
            row(id: "c", outcome: .skipped, notes: ["sandbox unavailable"]),
            row(id: "d", outcome: .errored, notes: ["watchdog timeout: …"]),
            row(
                id: "e",
                outcome: .skipped,
                notes: ["blocked: not run — process hung on prior case 'd' (watchdog timeout)"]
            ),
        ]
        let completed = EvalResume.completedRows(rows)
        #expect(completed.map(\.id) == ["a", "b", "c"])
    }

    @Test func sidecarRoundTripsAndResumeLoads() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("osaurus-resume-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let outPath = dir.appendingPathComponent("report.json").path

        let sink = try #require(EvalPartialRowSink(outPath: outPath))
        sink.append(row(id: "a", outcome: .passed, trials: 3, trialsPassed: 3))
        sink.append(row(id: "b", outcome: .errored))
        sink.close()

        let prior = EvalResume.loadPriorRows(outPath: outPath)
        #expect(prior.map(\.id) == ["a", "b"])
        #expect(prior[0].trials == 3)
        let completed = EvalResume.completedRows(prior)
        #expect(completed.map(\.id) == ["a"])

        // finalizeSuccess removes the sidecar.
        let sink2 = try #require(EvalPartialRowSink(outPath: outPath))
        sink2.append(row(id: "c", outcome: .passed))
        sink2.finalizeSuccess()
        #expect(
            !FileManager.default.fileExists(
                atPath: EvalResume.partialSidecarURL(forOut: outPath).path
            )
        )
    }

    @Test func loadPriorRowsFallsBackToReportJSON() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("osaurus-resume-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let outURL = dir.appendingPathComponent("report.json")

        let report = EvalReport(
            modelId: "m",
            startedAt: "2026-06-19T00:00:00Z",
            cases: [row(id: "a", outcome: .passed), row(id: "b", outcome: .failed)]
        )
        try report.toJSON().write(to: outURL)

        let prior = EvalResume.loadPriorRows(outPath: outURL.path)
        #expect(prior.map(\.id) == ["a", "b"])
    }
}
