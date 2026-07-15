import Foundation
import Testing

@testable import OsaurusEvalsKit

struct EvalScoreboardTests {
    @Test func scoreboardAggregatesFixtureDrivenReviewBundles() throws {
        let baselineReport = try fixtureReport("baseline")
        let currentReport = try fixtureReport("current")
        let baselineInput = input(suite: "AgentLoop", reportPath: "watcher/main/baseline/report/AgentLoop.json", report: baselineReport)
        let currentInput = input(suite: "AgentLoop", reportPath: "watcher/main/current/report/AgentLoop.json", report: currentReport)
        let baselineBundle = EvalReviewReportBuilder.build(
            manifest: manifest(
                generatedAt: "2026-06-17T00:00:00Z",
                commit: "base123",
                artifactPath: "build/evals/watcher/main/baseline/report"
            ),
            reports: [baselineInput]
        )
        let currentBundle = EvalReviewReportBuilder.build(
            manifest: manifest(
                generatedAt: "2026-06-18T00:00:00Z",
                commit: "head456",
                artifactPath: "build/evals/watcher/main/current/report",
                artifactId: "rc-agent-loop-head456",
                baselinePath: "build/evals/watcher/main/baseline/report"
            ),
            reports: [currentInput],
            baselineReports: [baselineInput]
        )

        let scoreboard = EvalScoreboardBuilder.build(
            generatedAt: "2026-06-18T01:00:00Z",
            sourceRoots: [URL(fileURLWithPath: "build/evals/watcher/main")],
            bundles: [
                EvalScoreboardInput(summaryPath: "baseline/summary.json", bundle: baselineBundle),
                EvalScoreboardInput(summaryPath: "current/summary.json", bundle: currentBundle),
            ]
        )

        let model = try #require(scoreboard.models.first)
        let suite = try #require(scoreboard.suites.first)

        #expect(scoreboard.runs.map(\.commit) == ["base123", "head456"])
        #expect(scoreboard.runs.last?.artifactId == "rc-agent-loop-head456")
        #expect(scoreboard.runs.last?.channel == "main")
        #expect(model.modelId == "foundation")
        #expect(model.runs == 2)
        #expect(model.counts.total == 12)
        #expect(model.counts.passed == 7)
        #expect(model.counts.failed == 4)
        #expect(model.counts.errored == 1)
        #expect(model.passRate == Double(7) / Double(12))
        #expect(model.blockingRegressions == 1)
        #expect(model.newFailures == 1)
        #expect(model.fixed == 1)
        #expect(model.persistentFailures == 1)
        #expect(suite.suite == "AgentLoop")
        #expect(suite.blockingRegressions == 1)
        #expect(scoreboard.comparison.bundlesWithBaseline == 1)
        #expect(scoreboard.comparison.blockingRegressions == 1)
        #expect(scoreboard.comparison.newFailures == 1)
        #expect(scoreboard.comparison.fixed == 1)
        #expect(scoreboard.comparison.persistentFailures == 1)
        #expect(scoreboard.comparison.newCases == 1)
        #expect(scoreboard.comparison.removedCases == 2)
        #expect(scoreboard.noRegression.allowedRegressions == 0)
        #expect(scoreboard.noRegression.observedRegressions == 2)
        #expect(!scoreboard.noRegression.passed)
        #expect(scoreboard.releaseCandidate?.artifactId == "rc-agent-loop-head456")
        #expect(scoreboard.releaseCandidate?.baselinePath == "build/evals/watcher/main/baseline/report")
        #expect(scoreboard.releaseCandidate?.local.first?.modelId == "foundation")
        #expect(scoreboard.releaseCandidate?.frontier.isEmpty == true)
        #expect(scoreboard.hasBlockingRegressions)

        let markdown = scoreboard.formatMarkdown()
        #expect(markdown.contains("# Eval Watcher Scoreboard"))
        #expect(markdown.contains("## Release Candidate Summary"))
        #expect(markdown.contains("- Artifact ID: `rc-agent-loop-head456`"))
        #expect(markdown.contains("- No-regression threshold: 2/0 breached"))
        #expect(markdown.contains("| local | foundation | 2 | 12 | 7 | 4 | 1 | 0 | 58.3% | 1 | 1 |"))
        #expect(markdown.contains("- Bundles with baseline: 1"))
        #expect(markdown.contains("build/evals/watcher/main/current/report"))
    }

    @Test func scoreboardHonorsRelaxedNoRegressionThreshold() throws {
        let baselineReport = try fixtureReport("baseline")
        let currentReport = try fixtureReport("current")
        let baselineInput = input(suite: "AgentLoop", reportPath: "baseline/AgentLoop.json", report: baselineReport)
        let currentInput = input(suite: "AgentLoop", reportPath: "current/AgentLoop.json", report: currentReport)
        let currentBundle = EvalReviewReportBuilder.build(
            manifest: manifest(
                generatedAt: "2026-06-18T00:00:00Z",
                commit: "head456",
                artifactPath: "build/evals/watcher/release-candidate/current/report",
                baselinePath: "build/evals/watcher/main/baseline/report"
            ),
            reports: [currentInput],
            baselineReports: [baselineInput]
        )

        let scoreboard = EvalScoreboardBuilder.build(
            generatedAt: "2026-06-18T01:00:00Z",
            sourceRoots: [URL(fileURLWithPath: "build/evals/watcher/release-candidate")],
            bundles: [EvalScoreboardInput(summaryPath: "current/summary.json", bundle: currentBundle)],
            allowedRegressions: 2
        )

        #expect(scoreboard.noRegression.observedRegressions == 2)
        #expect(scoreboard.noRegression.passed)
        #expect(!scoreboard.hasBlockingRegressions)
        #expect(scoreboard.releaseCandidate?.channel == "release-candidate")
        #expect(scoreboard.releaseCandidate?.noRegressionPassed == true)
        #expect(scoreboard.runs.first?.verdict == "EVAL FAILURES PRESENT")
    }

    @Test func scoreboardGatesLatestRunWhileKeepingRegressionHistory() throws {
        let baselineReport = try fixtureReport("baseline")
        let currentReport = try fixtureReport("current")
        let baselineInput = input(suite: "AgentLoop", reportPath: "baseline/AgentLoop.json", report: baselineReport)
        let regressedInput = input(suite: "AgentLoop", reportPath: "regressed/AgentLoop.json", report: currentReport)
        let recoveredInput = input(suite: "AgentLoop", reportPath: "recovered/AgentLoop.json", report: baselineReport)
        let regressedBundle = EvalReviewReportBuilder.build(
            manifest: manifest(
                generatedAt: "2026-06-18T00:00:00Z",
                commit: "regressed456",
                artifactPath: "build/evals/watcher/main/regressed/report",
                baselinePath: "build/evals/watcher/main/baseline/report"
            ),
            reports: [regressedInput],
            baselineReports: [baselineInput]
        )
        let recoveredBundle = EvalReviewReportBuilder.build(
            manifest: manifest(
                generatedAt: "2026-06-19T00:00:00Z",
                commit: "recovered789",
                artifactPath: "build/evals/watcher/main/recovered/report",
                baselinePath: "build/evals/watcher/main/baseline/report"
            ),
            reports: [recoveredInput],
            baselineReports: [baselineInput]
        )

        let scoreboard = EvalScoreboardBuilder.build(
            generatedAt: "2026-06-19T01:00:00Z",
            sourceRoots: [URL(fileURLWithPath: "build/evals/watcher/main")],
            bundles: [
                EvalScoreboardInput(summaryPath: "regressed/summary.json", bundle: regressedBundle),
                EvalScoreboardInput(summaryPath: "recovered/summary.json", bundle: recoveredBundle),
            ]
        )

        #expect(scoreboard.comparison.blockingRegressions == 1)
        #expect(scoreboard.comparison.newFailures == 1)
        #expect(scoreboard.noRegression.observedRegressions == 0)
        #expect(scoreboard.noRegression.passed)
        #expect(!scoreboard.hasBlockingRegressions)
        #expect(scoreboard.hasRunFailures)
        #expect(scoreboard.releaseCandidate?.commit == "recovered789")
        #expect(scoreboard.releaseCandidate?.noRegressionObserved == 0)
    }

    @Test func scoreboardRunFailureVerdictUsesLatestRun() throws {
        let baselineReport = try fixtureReport("baseline")
        let currentReport = try fixtureReport("current")
        let passingReport = passingFixtureReport()
        let baselineInput = input(suite: "AgentLoop", reportPath: "baseline/AgentLoop.json", report: baselineReport)
        let currentInput = input(suite: "AgentLoop", reportPath: "current/AgentLoop.json", report: currentReport)
        let passingInput = input(suite: "AgentLoop", reportPath: "passing/AgentLoop.json", report: passingReport)
        let baselineBundle = EvalReviewReportBuilder.build(
            manifest: manifest(
                generatedAt: "2026-06-17T00:00:00Z",
                commit: "base123",
                artifactPath: "build/evals/watcher/main/baseline/report"
            ),
            reports: [baselineInput]
        )
        let currentBundle = EvalReviewReportBuilder.build(
            manifest: manifest(
                generatedAt: "2026-06-18T00:00:00Z",
                commit: "head456",
                artifactPath: "build/evals/watcher/main/current/report"
            ),
            reports: [currentInput]
        )
        let passingBundle = EvalReviewReportBuilder.build(
            manifest: manifest(
                generatedAt: "2026-06-19T00:00:00Z",
                commit: "pass789",
                artifactPath: "build/evals/watcher/main/passing/report"
            ),
            reports: [passingInput]
        )

        let historicalFailure = EvalScoreboardBuilder.build(
            generatedAt: "2026-06-18T01:00:00Z",
            sourceRoots: [URL(fileURLWithPath: "build/evals/watcher/main")],
            bundles: [
                EvalScoreboardInput(summaryPath: "baseline/summary.json", bundle: baselineBundle),
                EvalScoreboardInput(summaryPath: "current/summary.json", bundle: currentBundle),
            ]
        )
        let recoveredLatest = EvalScoreboardBuilder.build(
            generatedAt: "2026-06-18T01:00:00Z",
            sourceRoots: [URL(fileURLWithPath: "build/evals/watcher/main")],
            bundles: [
                EvalScoreboardInput(summaryPath: "baseline/summary.json", bundle: baselineBundle),
                EvalScoreboardInput(summaryPath: "current/summary.json", bundle: currentBundle),
                EvalScoreboardInput(summaryPath: "passing/summary.json", bundle: passingBundle),
            ]
        )

        #expect(historicalFailure.hasRunFailures)
        #expect(!recoveredLatest.hasRunFailures)
    }

    @Test func loadBundlesRecursivelyConsumesEvidenceRegistrySnapshots() throws {
        let baselineReport = try fixtureReport("baseline")
        let bundle = EvalReviewReportBuilder.build(
            manifest: manifest(
                generatedAt: "2026-06-17T00:00:00Z",
                commit: "base123",
                artifactPath: "build/evals/watcher/main/baseline/report"
            ),
            reports: [
                input(
                    suite: "AgentLoop",
                    reportPath: "watcher/main/baseline/report/AgentLoop.json",
                    report: baselineReport
                ),
            ]
        )
        let root = try temporaryDirectory()
        let reportDir = root.appendingPathComponent("main/20260617T000000Z/report", isDirectory: true)
        try writeBundle(bundle, to: reportDir)
        let duplicateRegistryDir = root.appendingPathComponent("main/latest/report", isDirectory: true)
        try FileManager.default.createDirectory(at: duplicateRegistryDir, withIntermediateDirectories: true)
        try FileManager.default.copyItem(
            at: reportDir.appendingPathComponent(EvalReviewReportBundle.evidenceRegistryFileName),
            to: duplicateRegistryDir.appendingPathComponent(EvalReviewReportBundle.evidenceRegistryFileName)
        )
        let strayDir = root.appendingPathComponent("main/stray/report", isDirectory: true)
        try FileManager.default.createDirectory(at: strayDir, withIntermediateDirectories: true)
        try bundle.toJSON(prettyPrinted: true).write(to: strayDir.appendingPathComponent("summary.json"))

        let loaded = try EvalScoreboardBuilder.loadBundlesRecursively(from: [root])
        let scoreboard = EvalScoreboardBuilder.build(sourceRoots: [root], bundles: loaded)

        #expect(loaded.count == 1)
        #expect(loaded.first?.evidenceSummary.source == EvalReviewReportBundle.evidenceSource)
        #expect(scoreboard.runs.first?.commit == "base123")
        #expect(scoreboard.models.first?.counts.total == 6)
    }

    @Test func loadBundlesRecursivelyFailsOnInvalidRegistryBackedSummaryJSON() throws {
        let baselineReport = try fixtureReport("baseline")
        let bundle = EvalReviewReportBuilder.build(
            manifest: manifest(
                generatedAt: "2026-06-17T00:00:00Z",
                commit: "base123",
                artifactPath: "build/evals/watcher/main/invalid/report"
            ),
            reports: [
                input(
                    suite: "AgentLoop",
                    reportPath: "watcher/main/invalid/report/AgentLoop.json",
                    report: baselineReport
                ),
            ]
        )
        let root = try temporaryDirectory()
        let reportDir = root.appendingPathComponent("main/invalid/report", isDirectory: true)
        try FileManager.default.createDirectory(at: reportDir, withIntermediateDirectories: true)
        let summaryURL = reportDir.appendingPathComponent(EvalReviewReportBundle.summaryFileName)
        try Data("{".utf8).write(to: summaryURL)
        try bundle.evidenceRegistryJSON(summaryPath: summaryURL.path).write(
            to: reportDir.appendingPathComponent(EvalReviewReportBundle.evidenceRegistryFileName)
        )

        #expect(throws: EvalScoreboardError.self) {
            _ = try EvalScoreboardBuilder.loadBundlesRecursively(from: [root])
        }
    }

    @Test func reusedArtifactIdPrefersNewerRegisteredRun() throws {
        let root = try temporaryDirectory()
        let olderDir = root.appendingPathComponent("main/older/report", isDirectory: true)
        let newerDir = root.appendingPathComponent("main/newer/report", isDirectory: true)
        let artifactId = "stable-release-candidate"
        let olderBundle = EvalReviewReportBuilder.build(
            manifest: manifest(
                generatedAt: "2026-06-17T00:00:00Z",
                commit: "passing-old",
                artifactPath: olderDir.path,
                artifactId: artifactId
            ),
            reports: [
                input(
                    suite: "AgentLoop",
                    reportPath: olderDir.appendingPathComponent("AgentLoop.json").path,
                    report: passingFixtureReport()
                ),
            ]
        )
        let newerBundle = EvalReviewReportBuilder.build(
            manifest: manifest(
                generatedAt: "2026-06-18T00:00:00Z",
                commit: "failing-new",
                artifactPath: newerDir.path,
                artifactId: artifactId
            ),
            reports: [
                input(
                    suite: "AgentLoop",
                    reportPath: newerDir.appendingPathComponent("AgentLoop.json").path,
                    report: try fixtureReport("current")
                ),
            ]
        )
        try writeBundle(
            olderBundle,
            to: olderDir,
            registeredAt: Date(timeIntervalSince1970: 100)
        )
        try writeBundle(
            newerBundle,
            to: newerDir,
            registeredAt: Date(timeIntervalSince1970: 200)
        )

        let loaded = try EvalScoreboardBuilder.loadBundlesRecursively(from: [root])
        let scoreboard = EvalScoreboardBuilder.build(sourceRoots: [root], bundles: loaded)

        #expect(loaded.count == 1)
        #expect(loaded.first?.bundle.manifest.commit == "failing-new")
        #expect(scoreboard.releaseCandidate?.artifactId == artifactId)
        #expect(scoreboard.releaseCandidate?.commit == "failing-new")
        #expect(scoreboard.hasRunFailures)
    }

    @Test func scoreboardFailsClosedForZeroCaseReleaseCandidate() {
        let emptyReport = EvalReport(
            modelId: "foundation",
            startedAt: "2026-07-11T00:00:00Z",
            cases: []
        )
        let bundle = EvalReviewReportBuilder.build(
            manifest: manifest(
                generatedAt: "2026-07-11T00:00:00Z",
                commit: "zero-evidence",
                artifactPath: "build/evals/watcher/main/zero/report",
                artifactId: "zero-evidence"
            ),
            reports: [
                input(
                    suite: "AgentLoop",
                    reportPath: "build/evals/watcher/main/zero/report/AgentLoop.json",
                    report: emptyReport
                ),
            ]
        )

        let scoreboard = EvalScoreboardBuilder.build(
            sourceRoots: [URL(fileURLWithPath: "build/evals/watcher/main")],
            bundles: [EvalScoreboardInput(summaryPath: "summary.json", bundle: bundle)]
        )

        #expect(scoreboard.releaseCandidate?.artifactId == "zero-evidence")
        #expect(scoreboard.hasRunFailures)
        #expect(scoreboard.evidenceReportDescriptor(scoreboardPath: "scoreboard.json").status == .failed)
    }

    @Test func passingSiblingSuiteDoesNotMaskReleaseCandidateWithoutEvidence() {
        let bundle = EvalReviewReportBuilder.build(
            manifest: manifest(
                generatedAt: "2026-07-11T00:00:00Z",
                commit: "partial-evidence",
                artifactPath: "build/evals/watcher/main/partial/report",
                artifactId: "partial-evidence"
            ),
            reports: [
                input(
                    suite: "AgentLoop",
                    reportPath: "AgentLoop.json",
                    report: passingFixtureReport()
                ),
                input(
                    suite: "AgentLoopFrontier",
                    reportPath: "AgentLoopFrontier.json",
                    report: EvalReport(
                        modelId: "foundation",
                        startedAt: "2026-07-11T00:00:00Z",
                        cases: []
                    )
                ),
            ]
        )

        let scoreboard = EvalScoreboardBuilder.build(
            sourceRoots: [URL(fileURLWithPath: "build/evals/watcher/main")],
            bundles: [EvalScoreboardInput(summaryPath: "summary.json", bundle: bundle)]
        )

        #expect(scoreboard.releaseCandidate?.hasRunFailures == true)
        #expect(scoreboard.releaseCandidate?.verdict == "EVAL FAILURES PRESENT")
        #expect(scoreboard.hasRunFailures)
        #expect(scoreboard.evidenceReportDescriptor(scoreboardPath: "scoreboard.json").status == .failed)
    }

    @Test func latestPassingRunWithoutBaselineFailsNoRegressionGate() {
        let report = passingFixtureReport()
        let bundle = EvalReviewReportBuilder.build(
            manifest: manifest(
                generatedAt: "2026-06-19T00:00:00Z",
                commit: "head-without-baseline",
                artifactPath: "build/evals/watcher/release-candidate/current/report",
                artifactId: "missing-baseline"
            ),
            reports: [input(suite: "AgentLoop", reportPath: "AgentLoop.json", report: report)]
        )
        let scoreboard = EvalScoreboardBuilder.build(
            sourceRoots: [URL(fileURLWithPath: "build/evals/watcher/release-candidate")],
            bundles: [EvalScoreboardInput(summaryPath: "summary.json", bundle: bundle)]
        )

        #expect(scoreboard.noRegression.observedRegressions == 0)
        #expect(!scoreboard.noRegression.passed)
        #expect(scoreboard.releaseCandidate?.noRegressionPassed == false)
        #expect(scoreboard.releaseCandidate?.verdict == "NO COMPARABLE BASELINE")
        #expect(scoreboard.runs.first?.verdict == "NO COMPARABLE BASELINE")
        #expect(scoreboard.hasBlockingRegressions)
    }

    private func fixtureReport(_ name: String) throws -> EvalReport {
        let url = try #require(
            Bundle.module.url(
                forResource: name,
                withExtension: "json",
                subdirectory: "Fixtures/AgentLoopRegressionLab"
            )
        )
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(EvalReport.self, from: data)
    }

    private func passingFixtureReport() -> EvalReport {
        EvalReport(
            modelId: "foundation",
            startedAt: "2026-06-19T00:00:00Z",
            cases: [
                EvalCaseReport(
                    id: "agent_loop.clean",
                    label: "Clean",
                    domain: "agent_loop",
                    query: "clean case",
                    outcome: .passed,
                    notes: [],
                    modelId: "foundation",
                    latencyMs: 25
                ),
            ]
        )
    }

    private func input(
        suite: String,
        reportPath: String,
        report: EvalReport
    ) -> EvalReviewReportInput {
        EvalReviewReportInput(
            role: .local,
            suite: suite,
            suitePath: "Packages/OsaurusEvals/Suites/\(suite)",
            reportPath: reportPath,
            report: report
        )
    }

    private func manifest(
        generatedAt: String,
        commit: String,
        artifactPath: String,
        artifactId: String? = nil,
        baselinePath: String? = nil
    ) -> EvalReviewManifest {
        EvalReviewManifest(
            generatedAt: generatedAt,
            branch: "codex/eval-watcher-scoreboard",
            commit: commit,
            runner: "osaurus-evals report",
            artifactPath: artifactPath,
            artifactId: artifactId,
            suites: [
                EvalReviewSuiteRef(name: "AgentLoop", path: "Packages/OsaurusEvals/Suites/AgentLoop"),
            ],
            models: [
                EvalReviewModelRef(role: .local, modelId: "foundation"),
            ],
            commands: [],
            environment: EvalReviewEnvironmentSummary(
                operatingSystem: "macOS",
                ci: false,
                judgeModel: nil,
                sandboxFrontierIncluded: false
            ),
            baselinePath: baselinePath
        )
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("osaurus-eval-scoreboard-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func writeBundle(
        _ bundle: EvalReviewReportBundle,
        to reportDir: URL,
        registeredAt: Date = Date()
    ) throws {
        try FileManager.default.createDirectory(at: reportDir, withIntermediateDirectories: true)
        let summaryURL = reportDir.appendingPathComponent(EvalReviewReportBundle.summaryFileName)
        try bundle.toJSON(prettyPrinted: true).write(to: summaryURL, options: .atomic)
        try bundle.evidenceRegistryJSON(
            summaryPath: summaryURL.path,
            registeredAt: registeredAt
        ).write(
            to: reportDir.appendingPathComponent(EvalReviewReportBundle.evidenceRegistryFileName),
            options: .atomic
        )
    }
}
