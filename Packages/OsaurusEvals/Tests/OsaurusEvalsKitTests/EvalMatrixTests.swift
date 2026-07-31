import Foundation
import Testing

@testable import OsaurusEvalsKit

/// Locks the cross-model scoreboard's comparability caveats: mixed catalog
/// hashes, columns with no catalog hash, and self-judged columns must all
/// surface as warnings in the markdown and console renderings so a recorded
/// SNAPSHOT can't silently mix incomparable columns.
@Suite
struct EvalMatrixTests {

    private func column(
        model: String,
        passed: Int = 5,
        scored: Int = 10,
        env: RunEnvironment? = nil
    ) -> EvalMatrixModelColumn {
        EvalMatrixModelColumn(
            modelId: model,
            startedAt: "2026-06-19T00:00:00Z",
            perDomain: ["agent_loop": .init(passed: passed, scored: scored, skipped: 0, errored: 0)],
            totalPassed: passed,
            totalScored: scored,
            meanDecodeTokensPerSecond: nil,
            meanTtftMs: nil,
            peakPhysFootprintMb: nil,
            environment: env
        )
    }

    private func matrix(_ columns: [EvalMatrixModelColumn]) -> EvalMatrix {
        EvalMatrix(generatedAt: "2026-06-19T00:00:00Z", domains: ["agent_loop"], models: columns)
    }

    private func env(catalog: String?, judge: String = "xai/grok-4.3") -> RunEnvironment {
        RunEnvironment(
            chip: "Apple M4 Pro",
            totalRamMb: 49152,
            runModel: "m",
            judge: judge,
            catalogHash: catalog,
            caseCount: catalog == nil ? nil : 10
        )
    }

    @Test func sameCatalogSameJudgeYieldsNoWarnings() {
        let m = matrix([
            column(model: "a", env: env(catalog: "cafe")),
            column(model: "b", env: env(catalog: "cafe")),
        ])
        #expect(m.comparabilityWarnings.isEmpty)
        #expect(!m.formatMarkdown().contains("## Comparability"))
    }

    @Test func mixedCatalogHashesWarn() {
        let m = matrix([
            column(model: "a", env: env(catalog: "aaaa")),
            column(model: "prefix/b", env: env(catalog: "bbbb")),
        ])
        let warnings = m.comparabilityWarnings
        #expect(warnings.contains { $0.contains("DIFFERENT case catalogs") })
        #expect(warnings.contains { $0.contains("a=aaaa") && $0.contains("b=bbbb") })
        let md = m.formatMarkdown()
        #expect(md.contains("## Comparability"))
        #expect(md.contains("DIFFERENT case catalogs"))
        #expect(m.formatConsole().contains("DIFFERENT case catalogs"))
    }

    @Test func missingCatalogHashWarnsOnlyAgainstHashedColumns() {
        let m = matrix([
            column(model: "a", env: env(catalog: "cafe")),
            column(model: "b", env: env(catalog: nil)),
        ])
        #expect(m.comparabilityWarnings.contains { $0.contains("no catalog hash for: b") })

        // All-unhashed (legacy reports) stays silent — nothing to compare against.
        let legacy = matrix([
            column(model: "a", env: env(catalog: nil)),
            column(model: "b", env: env(catalog: nil)),
        ])
        #expect(legacy.comparabilityWarnings.isEmpty)
    }

    @Test func selfJudgedColumnWarns() {
        let m = matrix([
            column(model: "a", env: env(catalog: "cafe")),
            column(model: "b", env: env(catalog: "cafe", judge: "self-judge")),
        ])
        let warnings = m.comparabilityWarnings
        #expect(warnings.contains { $0.contains("self-judged column(s): b") })
    }

    @Test func chatModelAndSubsystemTotalsSplit() {
        let cases: [EvalCaseReport] = [
            .init(
                id: "agent_loop.ok", label: "ok", domain: "agent_loop", query: nil,
                outcome: .passed, notes: [], modelId: "m", latencyMs: 0
            ),
            .init(
                id: "apple_script.live-value-query", label: "live", domain: "apple_script",
                query: nil, outcome: .failed, notes: [], modelId: "m", latencyMs: 0
            ),
            .init(
                id: "subagent.image-generate-live", label: "image", domain: "subagent",
                query: nil, outcome: .passed, notes: [], modelId: "m", latencyMs: 0
            ),
        ]
        let col = EvalMatrixBuilder.build(from: [
            EvalReport(
                modelId: "m",
                startedAt: "2026-06-19T00:00:00Z",
                cases: cases,
                environment: nil
            ),
        ]).models[0]
        #expect(col.chatModelPassed == 1)
        #expect(col.chatModelScored == 1)
        #expect(col.subsystemPassed == 1)
        #expect(col.subsystemScored == 2)
        #expect(EvalMatrixBuilder.isSubsystemCase(id: "apple_script.live-value-query", domain: "apple_script"))
        #expect(EvalMatrixBuilder.isSubsystemCase(id: "subagent.image-generate-live", domain: "subagent"))
        #expect(!EvalMatrixBuilder.isSubsystemCase(id: "apple_script.scripted-value-query", domain: "apple_script"))
    }

    @Test func marketHarnessMetricsAggregateAgentLoopEfficiencyAndDelivery() {
        let cases: [EvalCaseReport] = [
            .init(
                id: "agent_loop.delivery-ok", label: "ok", domain: "agent_loop", query: nil,
                outcome: .passed,
                notes: ["summary: toolCalls=[file_write] iters=2 exit=finalResponse"],
                modelId: "m", latencyMs: 1_000,
                toolUsage: [.init(tool: "file_write", calls: 1, errors: 0, deduped: 0)],
                telemetry: .init(firstActionMs: 100, modelSteps: 2)
            ),
            .init(
                id: "agent_loop.delivery-loop", label: "loop", domain: "agent_loop", query: nil,
                outcome: .failed,
                notes: ["summary: toolCalls=[todo,file_write,file_read] iters=4 exit=iterationCapReached"],
                modelId: "m", latencyMs: 500,
                toolUsage: [
                    .init(tool: "todo", calls: 1, errors: 0, deduped: 0),
                    .init(tool: "file_write", calls: 1, errors: 0, deduped: 0),
                    .init(tool: "file_read", calls: 2, errors: 0, deduped: 1),
                ],
                telemetry: .init(firstActionMs: 200, modelSteps: 4)
            ),
        ]

        let col = EvalMatrixBuilder.build(from: [
            EvalReport(modelId: "m", startedAt: "2026-06-19T00:00:00Z", cases: cases)
        ]).models[0]

        #expect(col.meanFirstActionMs == 150)
        #expect(col.actionCompletionCoverage == 1)
        #expect(col.medianModelSteps == 3)
        #expect(col.loopFreeRate == 0.5)
        #expect(col.meanAgentLoopWallTimeMs == 750)
        #expect(col.correctFileDeliveryRate == 0.5)
        #expect(col.meanFrictionCalls == 1)
        #expect(col.totalPassed == 1)
        #expect(col.totalScored == 2)
    }

    @Test func loopMetricsPenalizeNoActionOversizedAndExecutedDuplicates() {
        let cases: [EvalCaseReport] = [
            .init(
                id: "agent_loop.clean", label: "clean", domain: "agent_loop", query: nil,
                outcome: .passed,
                notes: ["summary: toolCalls=[file_write] iters=2 exit=finalResponse"],
                modelId: "m", latencyMs: 1,
                toolUsage: [.init(tool: "file_write", calls: 1, errors: 0, deduped: 0)]
            ),
            .init(
                id: "agent_loop.no-action", label: "no action", domain: "agent_loop", query: nil,
                outcome: .failed,
                notes: ["summary: toolCalls=[] iters=1 exit=lengthExhausted"],
                modelId: "m", latencyMs: 1, toolUsage: []
            ),
            .init(
                id: "agent_loop.recovered", label: "recovered", domain: "agent_loop", query: nil,
                outcome: .passed,
                notes: [
                    "summary: toolCalls=[file_write] iters=2 exit=finalResponse",
                    "oversized tool call recoveries: 1",
                ],
                modelId: "m", latencyMs: 1,
                toolUsage: [.init(tool: "file_write", calls: 1, errors: 0, deduped: 0)]
            ),
            .init(
                id: "agent_loop.exhausted", label: "exhausted", domain: "agent_loop", query: nil,
                outcome: .failed,
                notes: [
                    "summary: toolCalls=[] iters=1 exit=oversizedToolCallExhausted"
                ],
                modelId: "m", latencyMs: 1, toolUsage: []
            ),
            .init(
                id: "agent_loop.duplicate", label: "duplicate", domain: "agent_loop", query: nil,
                outcome: .failed,
                notes: [
                    "1 duplicate call(s)",
                    "summary: toolCalls=[file_read,file_read] iters=3 exit=finalResponse",
                ],
                modelId: "m", latencyMs: 1,
                toolUsage: [.init(tool: "file_read", calls: 2, errors: 0, deduped: 0)]
            ),
        ]

        let col = EvalMatrixBuilder.build(from: [
            EvalReport(modelId: "m", startedAt: "2026-06-19T00:00:00Z", cases: cases)
        ]).models[0]
        #expect(col.actionCompletionCoverage == 0.6)
        #expect(col.loopFreeRate == 0.2)
    }

    @Test func missingRequiredFileCountsAsFailedDeliveryWithoutWriteCall() {
        let cases: [EvalCaseReport] = [
            .init(
                id: "agent_loop.delivered", label: "delivered", domain: "agent_loop",
                query: nil, outcome: .passed,
                notes: ["file 'report.md' contains 'done'"], modelId: "m", latencyMs: 1
            ),
            .init(
                id: "agent_loop.missing", label: "missing", domain: "agent_loop",
                query: nil, outcome: .failed,
                notes: ["file 'index.html' missing"], modelId: "m", latencyMs: 1,
                toolUsage: []
            ),
            .init(
                id: "agent_loop.escape", label: "escape", domain: "agent_loop",
                query: nil, outcome: .passed, notes: [], modelId: "m", latencyMs: 1,
                toolUsage: [.init(tool: "file_write", calls: 1, errors: 1, deduped: 0)]
            ),
        ]

        let col = EvalMatrixBuilder.build(from: [
            EvalReport(modelId: "m", startedAt: "2026-06-19T00:00:00Z", cases: cases)
        ]).models[0]

        #expect(col.correctFileDeliveryRate == 0.5)
    }

    @Test func sameModelDifferentHarnessesRemainSeparateColumns() {
        func report(harness: String, outcome: EvalCaseOutcome) -> EvalReport {
            EvalReport(
                modelId: "provider/same-model",
                startedAt: "2026-06-19T00:00:00Z",
                cases: [
                    .init(
                        id: "agent_loop.task", label: "task", domain: "agent_loop",
                        query: nil, outcome: outcome, notes: [], modelId: "provider/same-model",
                        latencyMs: 1
                    )
                ],
                environment: RunEnvironment(
                    runModel: "provider/same-model",
                    harness: harness,
                    catalogHash: "same"
                )
            )
        }

        let matrix = EvalMatrixBuilder.build(from: [
            report(harness: "osaurus", outcome: .passed),
            report(harness: "pi", outcome: .failed),
        ])

        #expect(matrix.models.count == 2)
        #expect(Set(matrix.models.compactMap(\.harness)) == ["osaurus", "pi"])
        #expect(matrix.formatMarkdown().contains("same-model [pi]"))
    }

    @Test func sparseExternalTelemetryWarnsWithoutInventingMeasurements() {
        let report = EvalReport(
            modelId: "shared-model",
            startedAt: "2026-06-19T00:00:00Z",
            cases: [
                EvalCaseReport(
                    id: "agent_loop.external",
                    label: "external",
                    domain: "agent_loop",
                    outcome: .passed,
                    notes: [],
                    modelId: "shared-model",
                    latencyMs: nil
                )
            ],
            environment: RunEnvironment(runModel: "shared-model", harness: "pi")
        )

        let matrix = EvalMatrixBuilder.build(from: [report])
        #expect(
            matrix.comparabilityWarnings.contains {
                $0.contains("runtime telemetry is incomplete")
                    && $0.contains("remain BLOCKED")
                    && $0.contains("no values were estimated")
            }
        )
        #expect(matrix.models[0].meanDecodeTokensPerSecond == nil)
        #expect(matrix.models[0].peakPhysFootprintMb == nil)
    }

    // MARK: - skip-reason histogram

    @Test func skipReasonsBuildFromSkippedCaseNotes() throws {
        let cases: [EvalCaseReport] = [
            .init(
                id: "agent_loop.ok", label: "ok", domain: "agent_loop", query: nil,
                outcome: .passed, notes: [], modelId: "m", latencyMs: 0
            ),
            .terminal(
                id: "agent_loop.sb1", label: "sb1", domain: "agent_loop",
                outcome: .skipped, notes: ["sandbox unavailable: OS too old"], modelId: "m"
            ),
            .terminal(
                id: "agent_loop.sb2", label: "sb2", domain: "agent_loop",
                outcome: .skipped, notes: ["sandbox unavailable: OS too old"], modelId: "m"
            ),
            .terminal(
                id: "agent_loop.plugin", label: "plugin", domain: "agent_loop",
                outcome: .skipped, notes: [], modelId: "m"
            ),
        ]
        let col = EvalMatrixBuilder.build(from: [
            EvalReport(modelId: "m", startedAt: "2026-06-19T00:00:00Z", cases: cases, environment: nil)
        ]).models[0]
        let cell = try #require(col.perDomain["agent_loop"])
        #expect(cell.skipped == 3)
        #expect(
            cell.skipReasons == [
                "sandboxUnavailable: sandbox unavailable: OS too old": 2,
                "unspecified": 1,
            ]
        )
        // Domains with no skips carry no histogram.
        #expect(cell.passed == 1)
    }

    @Test func repeatMetricsUseEveryRawTrialInsteadOfRepresentativeRow() {
        let trials: [EvalCaseReport.TrialSummary] = [
            .init(
                outcome: .passed,
                notes: [
                    "file 'index.html' contains 'done'",
                    "summary: toolCalls=[file_write] iters=2 exit=finalResponse",
                ],
                latencyMs: 100,
                toolUsage: [.init(tool: "file_write", calls: 1, errors: 0, deduped: 0)],
                telemetry: .init(firstActionMs: 50, totalModelTokens: 1_000, modelSteps: 2),
                context: nil
            ),
            .init(
                outcome: .failed,
                notes: [
                    "file 'index.html' missing",
                    "summary: toolCalls=[] iters=10 exit=iterationCapReached",
                ],
                latencyMs: 500,
                toolUsage: [],
                telemetry: .init(totalModelTokens: 5_000, modelSteps: 10),
                context: nil
            ),
        ]
        let merged = EvalCaseReport(
            id: "agent_loop.flaky",
            label: "flaky",
            domain: "agent_loop",
            outcome: .failed,
            notes: ["trials: 1/2 passed — FLAKY"],
            modelId: "m",
            latencyMs: 500,
            toolUsage: [],
            telemetry: .init(totalModelTokens: 5_000, modelSteps: 10),
            trials: 2,
            trialsPassed: 1,
            trialSummaries: trials
        )

        let col = EvalMatrixBuilder.build(from: [
            EvalReport(modelId: "m", startedAt: "2026-06-19T00:00:00Z", cases: [merged])
        ]).models[0]

        #expect(col.totalPassed == 1)
        #expect(col.totalScored == 2)
        #expect(col.meanAgentLoopWallTimeMs == 300)
        #expect(col.medianModelSteps == 6)
        #expect(col.actionCompletionCoverage == 0.5)
        #expect(col.loopFreeRate == 0.5)
        #expect(col.correctFileDeliveryRate == 0.5)
        #expect(col.meanTotalTokensPerTask == 3_000)
        #expect(col.flakyCases == 1)
    }

    @Test func preSchemaDomainCellDecodesWithNilSkipReasons() throws {
        // The 11 committed contributions predate `skipReasons`; their cells
        // must keep decoding, reading as "reasons unrecorded".
        let json = Data(#"{"passed": 5, "scored": 8, "skipped": 3, "errored": 0}"#.utf8)
        let cell = try JSONDecoder().decode(EvalMatrixDomainCell.self, from: json)
        #expect(cell.skipped == 3)
        #expect(cell.skipReasons == nil)
    }
}
