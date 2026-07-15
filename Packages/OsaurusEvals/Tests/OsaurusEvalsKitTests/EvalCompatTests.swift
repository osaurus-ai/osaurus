import Foundation
import Testing

@testable import OsaurusEvalsKit

/// Locks the crowdsourced compatibility aggregation: the verdict heuristic
/// (works / partial / broken), latest-run precedence (the newest catalog per
/// model defines the headline; same-catalog runs fold in; older runs become
/// History and are never pooled), the full ran/skip/err funnel with skip
/// reasons, per-domain strengths, the stale marker, and the `--validate`
/// PR gate that rejects provenance-less contributions.
@Suite
struct EvalCompatTests {

    private func column(
        model: String,
        passed: Int,
        scored: Int,
        skipped: Int = 0,
        errored: Int = 0,
        skipReasons: [String: Int]? = nil,
        decode: Double? = nil,
        peakRamMb: Double? = nil,
        startedAt: String = "2026-06-19T00:00:00Z",
        env: RunEnvironment? = nil
    ) -> EvalMatrixModelColumn {
        EvalMatrixModelColumn(
            modelId: model,
            startedAt: startedAt,
            perDomain: [
                "agent_loop": .init(
                    passed: passed,
                    scored: scored,
                    skipped: skipped,
                    errored: errored,
                    skipReasons: skipReasons
                )
            ],
            totalPassed: passed,
            totalScored: scored,
            meanDecodeTokensPerSecond: decode,
            meanTtftMs: nil,
            peakPhysFootprintMb: peakRamMb,
            environment: env
        )
    }

    private func matrix(_ columns: [EvalMatrixModelColumn]) -> EvalMatrix {
        EvalMatrix(generatedAt: "2026-06-19T00:00:00Z", domains: ["agent_loop"], models: columns)
    }

    private func env(
        chip: String,
        ramMb: Int,
        catalog: String,
        build: String = "1.2.3",
        judge: String = "xai/grok-4.3",
        contributor: String? = nil
    ) -> RunEnvironment {
        RunEnvironment(
            chip: chip,
            totalRamMb: ramMb,
            osVersion: "26.2.0",
            osaurusVersion: build,
            runModel: "m",
            judge: judge,
            catalogHash: catalog,
            caseCount: 1,
            contributor: contributor
        )
    }

    // MARK: - verdict heuristic

    @Test func verdictWorksWhenCleanAndPassing() {
        #expect(EvalCompatBuilder.verdict(passed: 10, scored: 10, errored: 0) == .works)
        #expect(EvalCompatBuilder.verdict(passed: 4, scored: 10, errored: 0) == .works)
    }

    @Test func verdictPartialOnErrorsOrLowPass() {
        #expect(EvalCompatBuilder.verdict(passed: 9, scored: 10, errored: 1) == .partial)
        #expect(EvalCompatBuilder.verdict(passed: 3, scored: 10, errored: 0) == .partial)
    }

    @Test func verdictBrokenWhenErrorDominatedOrNeverScored() {
        #expect(EvalCompatBuilder.verdict(passed: 0, scored: 0, errored: 6) == .broken)
        #expect(EvalCompatBuilder.verdict(passed: 1, scored: 2, errored: 5) == .broken)
    }

    @Test func verdictUnknownWhenNothingAttempted() {
        #expect(EvalCompatBuilder.verdict(passed: 0, scored: 0, errored: 0) == .unknown)
    }

    // MARK: - aggregation (same catalog folds across devices)

    @Test func foldsSameCatalogContributionsOfOneModel() {
        let c1 = matrix([
            column(
                model: "mlx-community/Qwen3-4B-4bit",
                passed: 8,
                scored: 10,
                decode: 60,
                peakRamMb: 5200,
                env: env(chip: "Apple M1 Pro", ramMb: 16384, catalog: "cafe")
            )
        ])
        let c2 = matrix([
            column(
                model: "mlx-community/Qwen3-4B-4bit",
                passed: 9,
                scored: 10,
                decode: 95,
                peakRamMb: 4800,
                env: env(chip: "Apple M3 Max", ramMb: 65536, catalog: "cafe")
            )
        ])
        let report = EvalCompatBuilder.build(from: [c1, c2])
        #expect(report.contributions == 2)
        #expect(report.models.count == 1)
        let m = report.models[0]
        #expect(m.contributions == 2)
        #expect(m.passed == 17)
        #expect(m.scored == 20)
        #expect(m.chips == ["Apple M1 Pro", "Apple M3 Max"])
        #expect(m.minRamMb == 16384)
        #expect(m.maxRamMb == 65536)
        #expect(m.peakPhysFootprintMb == 5200)  // worst observed
        #expect(m.decodeTokensPerSecondMin == 60)
        #expect(m.decodeTokensPerSecondMax == 95)
        #expect(m.catalogHash == "cafe")
        #expect(m.superseded.isEmpty)
        #expect(m.stale == false)
        #expect(m.verdict == .works)
    }

    // MARK: - latest-run precedence

    @Test func newestCatalogWinsAndOlderRunsBecomeHistory() {
        let old = matrix([
            column(
                model: "m",
                passed: 9,
                scored: 10,
                startedAt: "2026-06-01T00:00:00Z",
                env: env(chip: "Apple M1", ramMb: 8192, catalog: "aaaa", build: "0.9.0")
            )
        ])
        let new = matrix([
            column(
                model: "m",
                passed: 5,
                scored: 10,
                startedAt: "2026-07-01T00:00:00Z",
                env: env(chip: "Apple M4 Pro", ramMb: 49152, catalog: "bbbb", build: "1.0.0")
            )
        ])
        let m = EvalCompatBuilder.build(from: [old, new]).models[0]
        // Headline reflects ONLY the newest run — never pooled (5/10, not 14/20).
        #expect(m.passed == 5)
        #expect(m.scored == 10)
        #expect(m.contributions == 1)
        #expect(m.catalogHash == "bbbb")
        #expect(m.build == "1.0.0")
        #expect(m.asOf == "2026-07-01T00:00:00Z")
        #expect(m.chips == ["Apple M4 Pro"])
        // The old run is preserved as history.
        #expect(m.superseded.count == 1)
        #expect(m.superseded[0].catalogHash == "aaaa")
        #expect(m.superseded[0].passed == 9)
        #expect(m.superseded[0].scored == 10)
        #expect(m.superseded[0].chip == "Apple M1")
        #expect(m.stale == false)
    }

    @Test func sameCatalogAsNewestFoldsIntoCurrentSet() {
        let device1 = matrix([
            column(
                model: "m",
                passed: 8,
                scored: 10,
                startedAt: "2026-07-01T00:00:00Z",
                env: env(chip: "Apple M4 Pro", ramMb: 49152, catalog: "bbbb")
            )
        ])
        let device2 = matrix([
            column(
                model: "m",
                passed: 7,
                scored: 10,
                startedAt: "2026-06-28T00:00:00Z",
                env: env(chip: "Apple M2", ramMb: 16384, catalog: "bbbb")
            )
        ])
        let ancient = matrix([
            column(
                model: "m",
                passed: 1,
                scored: 10,
                startedAt: "2026-05-01T00:00:00Z",
                env: env(chip: "Apple M1", ramMb: 8192, catalog: "aaaa")
            )
        ])
        let m = EvalCompatBuilder.build(from: [device1, device2, ancient]).models[0]
        #expect(m.contributions == 2)
        #expect(m.passed == 15)
        #expect(m.scored == 20)
        #expect(m.superseded.count == 1)
        #expect(m.superseded[0].catalogHash == "aaaa")
    }

    @Test func modelStuckOnOldCatalogIsMarkedStale() {
        // Model `fresh` ran the newest catalog; model `old` only has a run
        // against the previous catalog → stale.
        let fresh = matrix([
            column(
                model: "fresh",
                passed: 8,
                scored: 10,
                startedAt: "2026-07-01T00:00:00Z",
                env: env(chip: "Apple M4 Pro", ramMb: 49152, catalog: "bbbb")
            )
        ])
        let old = matrix([
            column(
                model: "old",
                passed: 8,
                scored: 10,
                startedAt: "2026-06-01T00:00:00Z",
                env: env(chip: "Apple M1", ramMb: 8192, catalog: "aaaa")
            )
        ])
        let report = EvalCompatBuilder.build(from: [fresh, old])
        let byName = Dictionary(uniqueKeysWithValues: report.models.map { ($0.model, $0) })
        #expect(byName["fresh"]?.stale == false)
        #expect(byName["old"]?.stale == true)
        let md = report.formatMarkdown()
        #expect(md.contains("*(stale)*"))
        #expect(md.contains("`old`: stale"))
    }

    // MARK: - funnel + skip reasons + strengths

    @Test func funnelCountsAndSkipReasonsSurvivePerDomainMerge() throws {
        let c1 = matrix([
            column(
                model: "m",
                passed: 8,
                scored: 10,
                skipped: 3,
                errored: 1,
                skipReasons: ["sandbox unavailable": 3],
                env: env(chip: "Apple M4 Pro", ramMb: 49152, catalog: "cafe")
            )
        ])
        // Same catalog, second device: reasons merge; a pre-schema
        // contribution (skipReasons nil) leaves its skips unattributed.
        let c2 = matrix([
            column(
                model: "m",
                passed: 6,
                scored: 10,
                skipped: 2,
                env: env(chip: "Apple M2", ramMb: 16384, catalog: "cafe")
            )
        ])
        let m = EvalCompatBuilder.build(from: [c1, c2]).models[0]
        #expect(m.skipped == 5)
        #expect(m.errored == 1)
        #expect(m.attempted == 20 + 5 + 1)
        let cell = try #require(m.perDomain["agent_loop"])
        #expect(cell.skipped == 5)
        #expect(cell.skipReasons == ["sandbox unavailable": 3])
        let rendered = CompatibilityReport.formatSkipReasons(cell)
        #expect(rendered.contains("sandbox unavailable (3)"))
        #expect(rendered.contains("2 unrecorded"))
    }

    @Test func strengthsRequireVolumeAndHighPassRate() {
        let perDomain: [String: DomainCompatibility] = [
            "computer_use_loop": .init(passed: 10, scored: 10, skipped: 0, errored: 0, skipReasons: nil),
            "agent_loop": .init(passed: 60, scored: 100, skipped: 0, errored: 0, skipReasons: nil),
            // Perfect but tiny — not enough volume to call a strength.
            "micro_perf": .init(passed: 2, scored: 2, skipped: 0, errored: 0, skipReasons: nil),
        ]
        let (strengths, weakest) = EvalCompatBuilder.strengthsAndWeakest(perDomain)
        #expect(strengths == ["computer_use_loop"])
        #expect(weakest == "agent_loop")
    }

    @Test func weakestIsNilWhenEveryQualifyingDomainIsStrong() {
        let perDomain: [String: DomainCompatibility] = [
            "agent_loop": .init(passed: 19, scored: 20, skipped: 0, errored: 0, skipReasons: nil)
        ]
        let (strengths, weakest) = EvalCompatBuilder.strengthsAndWeakest(perDomain)
        #expect(strengths == ["agent_loop"])
        #expect(weakest == nil)
    }

    @Test func markdownRendersFunnelDetailsAndHistory() {
        let old = matrix([
            column(
                model: "acme/m-4bit",
                passed: 9,
                scored: 10,
                startedAt: "2026-06-01T00:00:00Z",
                env: env(chip: "Apple M1", ramMb: 8192, catalog: "aaaa")
            )
        ])
        let new = matrix([
            column(
                model: "acme/m-4bit",
                passed: 5,
                scored: 10,
                skipped: 2,
                skipReasons: ["plugin missing": 2],
                startedAt: "2026-07-01T00:00:00Z",
                env: env(chip: "Apple M4 Pro", ramMb: 49152, catalog: "bbbb")
            )
        ])
        let md = EvalCompatBuilder.build(from: [old, new]).formatMarkdown()
        // Headline funnel columns.
        #expect(md.contains("| Model | Verdict | Pass | Fail | Skip | Err |"))
        #expect(md.contains("50% (5/10) | 5 | 2 | 0"))
        // Detail section with per-domain table, skipped areas, and history.
        #expect(md.contains("## Model details"))
        #expect(md.contains("### `m-4bit`"))
        #expect(md.contains("catalog bbbb"))
        #expect(md.contains("| agent_loop | 50% (5/10) | 5 | 2 | 0 |"))
        #expect(md.contains("- agent_loop: 2 — plugin missing (2)"))
        #expect(md.contains("History (superseded, not in the headline):"))
        #expect(md.contains("2026-06-01"))
        #expect(md.contains("90% (9/10)"))
    }

    @Test func selfJudgedContributionRaisesCaveat() {
        let c = matrix([
            column(
                model: "m",
                passed: 5,
                scored: 10,
                env: env(chip: "Apple M1", ramMb: 8192, catalog: "aaaa", judge: "self-judge")
            )
        ])
        let m = EvalCompatBuilder.build(from: [c]).models[0]
        #expect(m.hasSelfJudged)
    }

    // MARK: - contributor attribution + ranking

    @Test func environmentContributorBeatsFileFallback() {
        let selfDeclared = EvalContribution(
            matrix: matrix([
                column(
                    model: "a",
                    passed: 8,
                    scored: 10,
                    env: env(chip: "Apple M4 Pro", ramMb: 49152, catalog: "cafe", contributor: "alice")
                )
            ]),
            fallbackContributor: "committer-bob"
        )
        let preSchema = EvalContribution(
            matrix: matrix([
                column(
                    model: "b",
                    passed: 7,
                    scored: 10,
                    env: env(chip: "Apple M1", ramMb: 8192, catalog: "cafe")
                )
            ]),
            fallbackContributor: "committer-bob"
        )
        let report = EvalCompatBuilder.build(from: [selfDeclared, preSchema])
        let byName = Dictionary(uniqueKeysWithValues: report.models.map { ($0.model, $0) })
        #expect(byName["a"]?.contributors == ["alice"])
        #expect(byName["b"]?.contributors == ["committer-bob"])
    }

    @Test func contributorRankingCountsAllRunsAndBreadth() throws {
        // alice: 3 runs (one superseded), 2 models, 2 device shapes.
        // bob: 1 run, 1 model, 1 device.
        let contributions = [
            EvalContribution(
                matrix: matrix([
                    column(
                        model: "m1",
                        passed: 8,
                        scored: 10,
                        startedAt: "2026-07-01T00:00:00Z",
                        env: env(chip: "Apple M4 Pro", ramMb: 49152, catalog: "new", contributor: "alice")
                    )
                ])
            ),
            EvalContribution(
                matrix: matrix([
                    column(
                        model: "m1",
                        passed: 5,
                        scored: 10,
                        startedAt: "2026-06-01T00:00:00Z",
                        env: env(chip: "Apple M1", ramMb: 8192, catalog: "old", contributor: "alice")
                    )
                ])
            ),
            EvalContribution(
                matrix: matrix([
                    column(
                        model: "m2",
                        passed: 9,
                        scored: 10,
                        startedAt: "2026-07-01T00:00:00Z",
                        env: env(chip: "Apple M4 Pro", ramMb: 49152, catalog: "new", contributor: "alice")
                    )
                ])
            ),
            EvalContribution(
                matrix: matrix([
                    column(
                        model: "m2",
                        passed: 6,
                        scored: 10,
                        startedAt: "2026-07-02T00:00:00Z",
                        env: env(chip: "Apple M3 Max", ramMb: 65536, catalog: "new", contributor: "bob")
                    )
                ])
            ),
        ]
        let report = EvalCompatBuilder.build(from: contributions)
        let ranking = try #require(report.contributors)
        #expect(ranking.count == 2)
        #expect(ranking[0] == ContributorRank(name: "alice", contributions: 3, models: 2, devices: 2))
        #expect(ranking[1] == ContributorRank(name: "bob", contributions: 1, models: 1, devices: 1))
        let md = report.formatMarkdown()
        #expect(md.contains("## Contributors"))
        // Contributors lead the report — rendered above the model table.
        let contributorsIndex = try #require(md.range(of: "## Contributors")?.lowerBound)
        let modelsIndex = try #require(md.range(of: "## Models")?.lowerBound)
        #expect(contributorsIndex < modelsIndex)
        // Top contributor is bolded; honor-roll prose credits everyone.
        #expect(md.contains("| 1 | **alice** | 3 | 2 | 2 |"))
        #expect(md.contains("| 2 | bob | 1 | 1 | 1 |"))
        #expect(md.contains("**alice** and **bob** donated machine-hours"))
        // Attribution shows up in the model details: m1's current run is
        // alice's alone; m2's current set folds alice + bob (same catalog).
        #expect(md.contains("by alice."))
        #expect(md.contains("by alice, bob."))
    }

    @Test func unattributedContributionsProduceNoRanking() {
        let report = EvalCompatBuilder.build(from: [
            matrix([
                column(model: "m", passed: 5, scored: 10, env: env(chip: "Apple M1", ramMb: 8192, catalog: "x"))
            ])
        ])
        #expect(report.contributors == nil)
        #expect(!report.formatMarkdown().contains("## Contributors"))
    }

    // MARK: - device coverage

    @Test func deviceCoverageGroupsByChipAndRam() {
        let contributions = [
            matrix([
                column(model: "a", passed: 1, scored: 1, env: env(chip: "Apple M1", ramMb: 8192, catalog: "x"))
            ]),
            matrix([
                column(model: "b", passed: 1, scored: 1, env: env(chip: "Apple M1", ramMb: 8192, catalog: "x"))
            ]),
            // Same chip, different RAM ⇒ a distinct device shape.
            matrix([
                column(model: "a", passed: 1, scored: 1, env: env(chip: "Apple M1", ramMb: 16384, catalog: "x"))
            ]),
            // No environment ⇒ skipped.
            matrix([column(model: "c", passed: 1, scored: 1)]),
        ]
        let devices = EvalCompatBuilder.deviceCoverage(from: contributions)
        #expect(devices.count == 2)
        #expect(devices[0].chip == "Apple M1")
        #expect(devices[0].totalRamMb == 8192)
        #expect(devices[0].contributions == 2)
        #expect(devices[1].totalRamMb == 16384)
        #expect(devices[1].contributions == 1)
    }

    @Test func reportCarriesDeviceCoverageAndRendersTable() {
        let report = EvalCompatBuilder.build(from: [
            matrix([
                column(model: "a", passed: 1, scored: 1, env: env(chip: "Apple M4 Pro", ramMb: 49152, catalog: "x"))
            ])
        ])
        #expect(report.devices?.count == 1)
        let md = report.formatMarkdown()
        #expect(md.contains("## Device coverage"))
        #expect(md.contains("| Apple M4 Pro | 48GB | 1 |"))
    }

    // MARK: - validation

    @Test func validateFlagsMissingProvenance() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("osaurus-compat-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        // No environment at all.
        let noEnv = matrix([column(model: "m", passed: 1, scored: 1)])
        try noEnv.toJSON().write(to: dir.appendingPathComponent("no-env.json"))
        // Env present but missing chip + catalogHash.
        let partial = matrix([
            column(model: "m", passed: 1, scored: 1, env: RunEnvironment(totalRamMb: 8192))
        ])
        try partial.toJSON().write(to: dir.appendingPathComponent("partial-env.json"))
        // Fully valid.
        let good = matrix([
            column(model: "m", passed: 1, scored: 1, env: env(chip: "Apple M1", ramMb: 8192, catalog: "aaaa"))
        ])
        try good.toJSON().write(to: dir.appendingPathComponent("good.json"))

        let problems = EvalCompatBuilder.validate(in: dir)
        #expect(problems.contains { $0.contains("no-env.json") && $0.contains("no environment") })
        #expect(problems.contains { $0.contains("partial-env.json") && $0.contains("chip") })
        #expect(problems.contains { $0.contains("partial-env.json") && $0.contains("catalogHash") })
        #expect(problems.contains { $0.contains("good.json") } == false)
    }

    @Test func loadContributionsRoundTripsMatrixAndReport() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("osaurus-compat-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        // A contribution matrix.
        let m = matrix([
            column(model: "a", passed: 1, scored: 1, env: env(chip: "Apple M1", ramMb: 8192, catalog: "aaaa"))
        ])
        try m.toJSON().write(to: dir.appendingPathComponent("contribution.json"))
        // A raw report (folded into a single-report matrix).
        let report = EvalReport(
            modelId: "b",
            startedAt: "2026-06-19T00:00:00Z",
            cases: [
                EvalCaseReport(
                    id: "c1",
                    label: "c1",
                    domain: "agent_loop",
                    outcome: .passed,
                    notes: [],
                    modelId: "b",
                    latencyMs: nil
                )
            ]
        )
        try report.toJSON().write(to: dir.appendingPathComponent("raw-report.json"))

        let matrices = try EvalCompatBuilder.loadContributions(in: dir)
        let built = EvalCompatBuilder.build(from: matrices)
        #expect(built.models.map(\.model).sorted() == ["a", "b"])
    }
}
