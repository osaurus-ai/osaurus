import Foundation
import Testing

@testable import OsaurusEvalsKit

/// Locks the crowdsourced compatibility aggregation: the verdict heuristic
/// (works / partial / broken), folding many contributions of one model into a
/// single row (summed pass/scored, hardware coverage, RAM band, decode range),
/// the comparability caveat when contributions graded different catalogs, and
/// the `--validate` PR gate that rejects provenance-less contributions.
@Suite
struct EvalCompatTests {

    private func column(
        model: String,
        passed: Int,
        scored: Int,
        skipped: Int = 0,
        errored: Int = 0,
        decode: Double? = nil,
        peakRamMb: Double? = nil,
        env: RunEnvironment? = nil
    ) -> EvalMatrixModelColumn {
        EvalMatrixModelColumn(
            modelId: model,
            startedAt: "2026-06-19T00:00:00Z",
            perDomain: ["agent_loop": .init(passed: passed, scored: scored, skipped: skipped, errored: errored)],
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
        judge: String = "xai/grok-4.3"
    ) -> RunEnvironment {
        RunEnvironment(
            chip: chip,
            totalRamMb: ramMb,
            osVersion: "26.2.0",
            osaurusVersion: build,
            runModel: "m",
            judge: judge,
            catalogHash: catalog,
            caseCount: 1
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

    // MARK: - aggregation

    @Test func foldsMultipleContributionsOfOneModel() {
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
        #expect(m.comparable)  // same catalog hash
        #expect(m.verdict == .works)
    }

    @Test func mixedCatalogHashesMarkNotComparable() {
        let c1 = matrix([
            column(model: "m", passed: 5, scored: 10, env: env(chip: "Apple M1", ramMb: 8192, catalog: "aaaa"))
        ])
        let c2 = matrix([
            column(model: "m", passed: 5, scored: 10, env: env(chip: "Apple M1", ramMb: 8192, catalog: "bbbb"))
        ])
        let m = EvalCompatBuilder.build(from: [c1, c2]).models[0]
        #expect(m.catalogHashes.count == 2)
        #expect(m.comparable == false)
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
