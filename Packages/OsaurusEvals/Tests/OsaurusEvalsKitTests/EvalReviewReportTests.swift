import Foundation
import Testing

@testable import OsaurusEvalsKit

struct EvalReviewReportTests {
    @Test func aggregateSummaryCountsOutcomesAcrossModelsAndSuites() throws {
        let bundle = EvalReviewReportBuilder.build(
            manifest: manifest(commands: [
                EvalReviewCommandRecord(
                    role: .local,
                    modelId: "foundation",
                    suite: "AgentLoop",
                    suitePath: "Suites/AgentLoop",
                    outputPath: "build/evals/pr-report/reports/foundation/AgentLoop.json",
                    arguments: ["osaurus-evals", "run", "--suite", "Suites/AgentLoop"],
                    exitCode: 1
                ),
            ]),
            reports: [
                input(
                    role: .local,
                    suite: "AgentLoop",
                    report: report(
                        modelId: "foundation",
                        rows: [
                            ("agent_loop.pass", .passed, []),
                            ("agent_loop.fail", .failed, ["missing expected edit"]),
                            ("agent_loop.skip", .skipped, ["sandbox unavailable"]),
                        ]
                    )
                ),
                input(
                    role: .local,
                    suite: "AgentLoopFrontier",
                    report: report(
                        modelId: "foundation",
                        rows: [
                            ("agent_loop.frontier-pass", .passed, []),
                            ("agent_loop.frontier-error", .errored, ["agent loop error"]),
                        ]
                    )
                ),
                input(
                    role: .frontier,
                    suite: "AgentLoop",
                    report: report(
                        modelId: "openai/gpt-4o-mini",
                        rows: [
                            ("agent_loop.pass", .passed, []),
                            ("agent_loop.second-pass", .passed, []),
                        ]
                    )
                ),
            ]
        )

        let local = try #require(bundle.models.first { $0.role == .local })
        let frontier = try #require(bundle.models.first { $0.role == .frontier })

        #expect(local.counts.total == 5)
        #expect(local.counts.passed == 2)
        #expect(local.counts.failed == 1)
        #expect(local.counts.errored == 1)
        #expect(local.counts.skipped == 1)
        #expect(frontier.counts.passed == 2)
        #expect(bundle.hasRunFailures)

        let markdown = bundle.formatMarkdown()
        #expect(markdown.contains("Eval evidence:"))
        #expect(markdown.contains("foundation, AgentLoop 1/3, AgentLoopFrontier 1/2"))
        #expect(markdown.contains("openai/gpt-4o-mini, AgentLoop 2/2"))
        #expect(markdown.contains("agent_loop.fail"))
        #expect(markdown.contains("sandbox unavailable"))
        #expect(markdown.contains("osaurus-evals run --suite Suites/AgentLoop"))
        #expect(markdown.contains("build/evals/pr-report"))
    }

    @Test func baselineComparisonClassifiesRegressionsAndDrift() throws {
        let baselineReports = [
            input(
                role: .local,
                suite: "AgentLoop",
                report: report(
                    modelId: "foundation",
                    rows: [
                        ("regression", .passed, []),
                        ("fixed", .failed, ["old failure"]),
                        ("persistent", .failed, ["still failing before"]),
                        ("changed-skip", .skipped, ["missing sandbox before"]),
                        ("removed", .passed, []),
                    ]
                )
            ),
        ]
        let currentReports = [
            input(
                role: .local,
                suite: "AgentLoop",
                report: report(
                    modelId: "foundation",
                    rows: [
                        ("regression", .failed, ["new failure"]),
                        ("fixed", .passed, []),
                        ("persistent", .errored, ["still failing now"]),
                        ("changed-skip", .passed, []),
                        ("new-failure", .errored, ["new error"]),
                        ("new-pass", .passed, []),
                    ]
                )
            ),
        ]

        let bundle = EvalReviewReportBuilder.build(
            manifest: manifest(baselinePath: "build/evals/baseline"),
            reports: currentReports,
            baselineReports: baselineReports
        )
        let comparison = try #require(bundle.comparison)

        #expect(comparison.hasBlockingRegressions)
        #expect(comparison.regressions.map(\.id) == ["regression"])
        #expect(comparison.newFailures.map(\.id) == ["new-failure"])
        #expect(comparison.fixed.map(\.id) == ["fixed"])
        #expect(comparison.persistentFailures.map(\.id) == ["persistent"])
        #expect(comparison.changedSkips.map(\.id) == ["changed-skip"])
        #expect(comparison.newCases.map(\.id) == ["new-pass"])
        #expect(comparison.removedCases.map(\.id) == ["removed"])

        let compareMarkdown = bundle.formatComparisonMarkdown()
        #expect(compareMarkdown.contains("## Blocking Regressions"))
        #expect(compareMarkdown.contains("new-failure"))
        #expect(compareMarkdown.contains("changed-skip"))
    }

    @Test func missingReportProducesExplicitErroredSummaryRow() throws {
        let missing = EvalReviewReportBuilder.missingReport(
            role: .frontier,
            modelId: "openai/gpt-4o-mini",
            suite: EvalReviewSuiteRef(name: "AgentLoopFrontier", path: "Suites/AgentLoopFrontier"),
            reportPath: "build/evals/pr-report/reports/openai_gpt-4o-mini/AgentLoopFrontier.json",
            note: "frontier report did not finish"
        )
        let bundle = EvalReviewReportBuilder.build(
            manifest: manifest(),
            reports: [missing]
        )
        let frontier = try #require(bundle.models.first)
        let suite = try #require(frontier.suites.first)

        #expect(bundle.hasRunFailures)
        #expect(frontier.counts.errored == 1)
        #expect(suite.errors.first?.id == "missing-report.AgentLoopFrontier")
        #expect(suite.errors.first?.notes == ["frontier report did not finish"])
    }

    @Test func existingEvalReportJSONRemainsCompatible() throws {
        let original = report(
            modelId: "foundation",
            rows: [
                ("agent_loop.pass", .passed, []),
                ("agent_loop.error", .errored, ["boom"]),
            ]
        )
        let encoded = try original.toJSON(prettyPrinted: true)
        let decoded = try JSONDecoder().decode(EvalReport.self, from: encoded)

        #expect(decoded.modelId == original.modelId)
        #expect(decoded.cases.map(\.id) == ["agent_loop.pass", "agent_loop.error"])
        #expect(decoded.counts.errored == 1)
    }

    private func input(
        role: EvalReviewModelRole,
        suite: String,
        report: EvalReport
    ) -> EvalReviewReportInput {
        EvalReviewReportInput(
            role: role,
            suite: suite,
            suitePath: "Suites/\(suite)",
            reportPath: "build/evals/pr-report/reports/\(report.modelId)/\(suite).json",
            report: report
        )
    }

    private func report(
        modelId: String,
        rows: [(id: String, outcome: EvalCaseOutcome, notes: [String])]
    ) -> EvalReport {
        EvalReport(
            modelId: modelId,
            startedAt: "2026-06-18T12:00:00Z",
            cases: rows.map { row in
                EvalCaseReport(
                    id: row.id,
                    label: row.id,
                    domain: "agent_loop",
                    query: "do work",
                    outcome: row.outcome,
                    notes: row.notes,
                    modelId: modelId,
                    latencyMs: 10
                )
            }
        )
    }

    private func manifest(
        baselinePath: String? = nil,
        commands: [EvalReviewCommandRecord] = []
    ) -> EvalReviewManifest {
        EvalReviewManifest(
            generatedAt: "2026-06-18T12:00:00Z",
            branch: "feature/eval-report",
            commit: "abc123",
            runner: "osaurus-evals report",
            artifactPath: "build/evals/pr-report",
            suites: [
                EvalReviewSuiteRef(name: "AgentLoop", path: "Suites/AgentLoop"),
                EvalReviewSuiteRef(name: "AgentLoopFrontier", path: "Suites/AgentLoopFrontier"),
            ],
            models: [
                EvalReviewModelRef(role: .local, modelId: "foundation"),
                EvalReviewModelRef(role: .frontier, modelId: "openai/gpt-4o-mini"),
            ],
            commands: commands,
            environment: EvalReviewEnvironmentSummary(
                operatingSystem: "macOS",
                ci: false,
                judgeModel: "openai/gpt-4o-mini",
                sandboxFrontierIncluded: false
            ),
            baselinePath: baselinePath
        )
    }
}
